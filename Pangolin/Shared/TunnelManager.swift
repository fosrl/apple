import Combine
import Foundation
import NetworkExtension
import os.log

#if os(iOS)
    import WidgetKit
#endif

#if os(macOS)
    import SystemExtensions
#endif

class TunnelManager: NSObject, ObservableObject {
    @Published var isNEConnected = false
    @Published var status: TunnelStatus = .disconnected
    /// Mirrors WireGuard `isActivateOnDemandEnabled` (isOnDemandEnabled && isEnabled).
    @Published var isOnDemandEnabled = false
    /// True when the NE profile has on-demand rules configured (prefs), whether or not engaged.
    @Published var hasOnDemandRules = false
    /// Set when a connect attempt fails (socket error, missing config, startVPNTunnel, etc.).
    /// Cleared at the start of `connect()`. App Intents read this after `waitUntilSettled()`.
    private(set) var lastConnectionError: String?

    private var tunnelManager: NETunnelProviderManager?
    #if os(iOS)
        private let bundleIdentifier = "net.pangolin.Pangolin.PangoliniOS.PacketTunneliOS"
    #else
        private let bundleIdentifier = "net.pangolin.Pangolin.PacketTunnel"
    #endif
    private var statusObserver: NSObjectProtocol?
    #if os(macOS)
        private var systemExtensionRequest: OSSystemExtensionRequest?
        private var systemExtensionInstallContinuation: CheckedContinuation<Bool, Error>?
    #endif

    // Version tracking for extension updates
    private let extensionVersionKey = "net.pangolin.Pangolin.PacketTunnel.lastKnownVersion"

    private let configManager: ConfigManager
    private let accountManager: AccountManager
    private let secretManager: SecretManager
    private let authManager: AuthManager
    private let socketManager: SocketManager

    // Separate manager for OLM status to avoid menu bar re-renders
    let olmStatusManager: OLMStatusManager

    // Fingerprint/posture checking poller
    let fingerprintManager: FingerprintManager

    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return OSLog(subsystem: subsystem, category: "TunnelManager")
    }()

    // Socket polling
    private var socketPollingTask: Task<Void, Never>?
    private let socketPollInterval: TimeInterval = 1.0
    private var isPollingSocket = false

    // Flag to prevent duplicate error alerts
    private nonisolated(unsafe) var hasShownErrorAlert = false

    // Cache last known values to avoid unnecessary updates
    private nonisolated(unsafe) var lastTunnelStatus: TunnelStatus?
    private nonisolated(unsafe) var lastIsNEConnected: Bool = false

    #if os(iOS)
        private var liveActivityCancellable: AnyCancellable?
        private var widgetMetadataCancellables = Set<AnyCancellable>()
    #endif

    /// Socket error codes that indicate session expired; re-auth button should be shown.
    private static let sessionExpiredSocketErrorCodes: Set<String> = [
        "UNAUTHORIZED",
        "SESSION_EXPIRED",
        "ORG_ACCESS_POLICY_SESSION_EXPIRED",
        "INVALID_USER_SESSION",
        "USER_ID_NOT_FOUND",
    ]

    init(
        configManager: ConfigManager,
        accountManager: AccountManager,
        secretManager: SecretManager,
        authManager: AuthManager,
    ) {
        self.configManager = configManager
        self.accountManager = accountManager
        self.secretManager = secretManager
        self.authManager = authManager
        self.socketManager = SocketManager()
        self.olmStatusManager = OLMStatusManager(socketManager: self.socketManager)
        self.fingerprintManager = FingerprintManager()
        #if os(macOS)
            self.fingerprintManager.startCacheRefresh(interval: 3 * 3600)
        #endif
        super.init()

        // Observe VPN status changes
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.updateConnectionStatus()
            }
        }

        #if os(iOS)
            liveActivityCancellable = $status
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newStatus in
                    self?.syncLiveActivity(status: newStatus)
                    self?.syncWidgetStatus(status: newStatus)
                }

            // On-demand engage can leave TunnelStatus at .disconnected; still refresh widget.
            $isOnDemandEnabled
                .combineLatest($hasOnDemandRules)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _ in
                    guard let self else { return }
                    self.syncWidgetStatus(status: self.status)
                }
                .store(in: &widgetMetadataCancellables)

            // Org / account can change while tunnel status stays the same; refresh
            // the widget so cleared selections don't leave stale labels.
            authManager.$currentOrg
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.syncWidgetStatus(status: self.status)
                }
                .store(in: &widgetMetadataCancellables)

            authManager.$isAuthenticated
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.syncWidgetStatus(status: self.status)
                }
                .store(in: &widgetMetadataCancellables)

            accountManager.$store
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.syncWidgetStatus(status: self.status)
                }
                .store(in: &widgetMetadataCancellables)
        #endif

        Task {
            #if os(macOS)
                // Defer system extension and VPN setup until the user completes onboarding
                // (or taps Connect). Only update status if a configuration already exists,
                // to avoid showing system prompts on launch.
                if await hasRegisteredExtension() {
                    await refreshInstalledSystemExtensionOnLaunch()
                    await ensureExtensionRegistered()
                    await updateConnectionStatus()
                } else {
                    await MainActor.run {
                        self.isNEConnected = false
                        self.status = .disconnected
                    }
                }
            #else
                // On iOS, defer installing/registering the VPN configuration until
                // the user explicitly requests it (e.g. from onboarding or connect).
                // Here we only update any cached status if a configuration already
                // exists, to avoid triggering the system VPN prompt on first launch.
                if await hasRegisteredExtension() {
                    await ensureExtensionRegistered()
                    await updateConnectionStatus()
                } else {
                    await MainActor.run {
                        self.isNEConnected = false
                        self.status = .disconnected
                    }
                }
                await MainActor.run {
                    self.reconcileLiveActivityOnLaunch()
                    self.syncWidgetStatus(status: self.status)
                }
            #endif
        }
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stopSocketPolling()
    }

    /// Re-reads NE VPN + on-demand state and pushes the widget snapshot.
    /// Call when the app becomes active so background on-demand changes are reflected.
    func updateConnectionStatusForWidget() async {
        await updateConnectionStatus()
        #if os(iOS)
        await MainActor.run {
            syncWidgetStatus(status: status)
        }
        #endif
    }

    @MainActor
    private func updateConnectionStatus() async {
        guard let manager = tunnelManager else {
            isNEConnected = false
            status = .disconnected
            isOnDemandEnabled = false
            hasOnDemandRules = false
            stopSocketPolling()
            return
        }

        syncOnDemandState(from: manager)

        let vpnStatus = manager.connection.status

        // Simple state handling:
        // - disconnected: Network extension is stopped
        // - starting: User clicked connect, gathering fingerprint (preserved during this phase)
        // - registering: Extension is running, polling socket
        // - connected: Socket shows registered=true and connected=true
        switch vpnStatus {
        case .disconnected:
            // If we're in starting state, preserve it (fingerprint gathering in progress)
            if status != .starting {
                status = .disconnected
                isNEConnected = false
                stopSocketPolling()
            }
        case .connecting:
            // Extension is starting, transition to registering
            status = .registering
            isNEConnected = true  // Extension is running, show disconnect button
            stopSocketPolling()
        case .connected:
            // Extension is connected, start polling socket
            isNEConnected = true
            if !isPollingSocket && !hasShownErrorAlert {
                startSocketPolling()
                status = .registering
            }
        case .reasserting:
            // Extension is reasserting, keep current state
            break
        case .disconnecting:
            // Extension is disconnecting, show disconnected
            status = .disconnected
            isNEConnected = false
            stopSocketPolling()
        default:
            // For any other status, show disconnected
            status = .disconnected
            isNEConnected = false
            stopSocketPolling()
        }

        os_log(
            "VPN Status changed: %{public}@ (VPN status: %d, onDemand=%{public}d rules=%{public}d)",
            log: logger, type: .debug,
            status.displayText, vpnStatus.rawValue,
            isOnDemandEnabled ? 1 : 0, hasOnDemandRules ? 1 : 0)
    }

    /// WireGuard-equivalent: engaged = isOnDemandEnabled && isEnabled; has rules = non-empty onDemandRules.
    @MainActor
    private func syncOnDemandState(from manager: NETunnelProviderManager) {
        isOnDemandEnabled = manager.isOnDemandEnabled && manager.isEnabled
        hasOnDemandRules = !(manager.onDemandRules ?? []).isEmpty
    }

    #if os(macOS)
        /// Installs or activates the Packet Tunnel system extension. Returns true on success.
        func installSystemExtensionIfNeeded() async -> Bool {
            os_log("Installing/activating system extension...", log: logger, type: .info)

            await MainActor.run {
                status = .registering
            }

            let manager = OSSystemExtensionManager.shared
            // Always use activationRequest - the system will automatically detect if replacement is needed
            // and call the delegate method actionForReplacingExtension
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: bundleIdentifier,
                queue: .main
            )

            request.delegate = self

            do {
                let result = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Bool, Error>) in
                    systemExtensionInstallContinuation = continuation
                    systemExtensionRequest = request
                    manager.submitRequest(request)
                }

                return result
            } catch {
                os_log(
                    "Failed to install system extension: %{public}@", log: logger, type: .error,
                    error.localizedDescription)
                await MainActor.run {
                    status = .disconnected
                }
                return false
            }
        }
    #endif

    // MARK: - Extension Version Management

    /// Gets the current version of the PacketTunnel extension from its bundle
    /// This is a public method for displaying the version in the UI
    func getExtensionVersion() -> String? {
        return getCurrentExtensionVersion()
    }

    /// Gets the current version of the PacketTunnel extension from its bundle
    private func getCurrentExtensionVersion() -> String? {
        // The PacketTunnel extension bundle is embedded in the main app bundle
        // Search for it by bundle identifier in the PlugIns directory
        let mainBundle = Bundle.main.bundleURL

        // Look for the extension bundle in the app's PlugIns directory
        // On macOS: Contents/PlugIns, on iOS: PlugIns
        #if os(iOS)
            let pluginsURL = mainBundle.appendingPathComponent("PlugIns", isDirectory: true)
        #else
            let pluginsURL = mainBundle.appendingPathComponent(
                "Contents/PlugIns", isDirectory: true)
        #endif

        // Check if PlugIns directory exists
        guard FileManager.default.fileExists(atPath: pluginsURL.path) else {
            os_log(
                "PlugIns directory does not exist at %{public}@ (this may be normal during early initialization)",
                log: logger, type: .debug, pluginsURL.path)
            return nil
        }

        // Search for the extension bundle by enumerating PlugIns directory
        guard
            let pluginContents = try? FileManager.default.contentsOfDirectory(
                at: pluginsURL, includingPropertiesForKeys: nil, options: [])
        else {
            os_log("Could not enumerate PlugIns directory", log: logger, type: .debug)
            return nil
        }

        // Find the extension bundle by checking its bundle identifier
        for pluginURL in pluginContents {
            guard pluginURL.pathExtension == "appex",
                let extensionBundle = Bundle(url: pluginURL),
                let pluginBundleId = extensionBundle.bundleIdentifier,
                pluginBundleId == bundleIdentifier
            else {
                continue
            }

            // Found the extension bundle, get its version
            guard
                let version = extensionBundle.object(forInfoDictionaryKey: "CFBundleVersion")
                    as? String
            else {
                os_log(
                    "Could not get CFBundleVersion from extension bundle at %{public}@",
                    log: logger, type: .error, pluginURL.path)
                return nil
            }

            os_log(
                "Found extension bundle at %{public}@ with version %{public}@", log: logger,
                type: .debug, pluginURL.path, version)
            return version
        }

        os_log(
            "Could not find PacketTunnel extension bundle with identifier %{public}@ in PlugIns directory",
            log: logger, type: .debug, bundleIdentifier)
        return nil
    }

    /// Gets the last known version of the extension from UserDefaults
    private func getLastKnownExtensionVersion() -> String? {
        return UserDefaults.standard.string(forKey: extensionVersionKey)
    }

    /// Stores the extension version in UserDefaults
    private func setLastKnownExtensionVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: extensionVersionKey)
    }

    #if os(macOS)
        /// If a profile is already installed, submit activation on launch so macOS can
        /// update/replace the installed system extension if needed.
        private func refreshInstalledSystemExtensionOnLaunch() async {
            os_log(
                "Existing VPN profile detected on launch; triggering system extension activation/update check",
                log: logger, type: .info)
            let refreshed = await installSystemExtensionIfNeeded()
            if !refreshed {
                os_log(
                    "System extension refresh on launch did not complete successfully",
                    log: logger, type: .error)
            }
        }
    #endif

    // MARK: - VPN Profile / Extension Helpers

    /// Checks whether a NETunnelProviderManager for the Pangolin packet tunnel
    /// extension already exists in the user's VPN configurations.
    func isVPNProfileInstalled() async -> Bool {
        await hasRegisteredExtension()
    }

    /// Ensures that the VPN profile is installed, prompting the user to allow
    /// the configuration if needed.
    ///
    /// Returns `true` if a profile exists after this call (either pre-existing
    /// or newly created), and `false` if creation failed.
    func ensureVPNProfileInstalled() async -> Bool {
        // Fast path: configuration already exists.
        if await hasRegisteredExtension() {
            return true
        }

        // Otherwise, attempt to register the extension, which will trigger
        // the iOS VPN configuration prompt as needed.
        await ensureExtensionRegistered()

        // Re-check after attempting registration.
        return await hasRegisteredExtension()
    }

    /// Internal helper that inspects existing NETunnelProviderManager instances
    /// without creating or modifying any configuration.
    private func hasRegisteredExtension() async -> Bool {
        let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
        let existingManager = managers?.first { manager in
            guard let protocolConfig = manager.protocolConfiguration as? NETunnelProviderProtocol
            else {
                return false
            }
            return protocolConfig.providerBundleIdentifier == bundleIdentifier
        }

        return existingManager != nil
    }

    func ensureExtensionRegistered() async {
        if let managers = try? await NETunnelProviderManager.loadAllFromPreferences(),
            let existingManager = managers.first(where: { manager in
                guard
                    let protocolConfig = manager.protocolConfiguration
                        as? NETunnelProviderProtocol
                else {
                    return false
                }
                return protocolConfig.providerBundleIdentifier == bundleIdentifier
            })
        {
            // Reload to get the actual manager instance
            do {
                try await existingManager.loadFromPreferences()
                await MainActor.run {
                    tunnelManager = existingManager
                }
                await updateConnectionStatus()
            } catch {
                os_log(
                    "Error loading manager: %{public}@", log: logger, type: .error,
                    error.localizedDescription)
            }
        } else {
            // Register the extension
            await registerExtension()
        }
    }

    private func registerExtension() async {
        let manager = NETunnelProviderManager()

        // Configure the tunnel protocol
        let protocolConfiguration = NETunnelProviderProtocol()
        protocolConfiguration.providerBundleIdentifier = bundleIdentifier
        protocolConfiguration.serverAddress = "Pangolin"  // Use a descriptive name, not bundle ID

        manager.protocolConfiguration = protocolConfiguration
        manager.localizedDescription = "Pangolin"
        manager.isEnabled = true

        do {
            try await manager.saveToPreferences()
            // IMPORTANT: Reload after saving to get the actual manager instance
            try await manager.loadFromPreferences()

            await MainActor.run {
                tunnelManager = manager
            }
            await updateConnectionStatus()
        } catch {
            os_log(
                "Error registering extension: %{public}@", log: logger, type: .error,
                error.localizedDescription)
            await MainActor.run {
                status = .disconnected
            }
        }
    }

    func connect() async {
        // Clear error alert flag for new connection attempt
        hasShownErrorAlert = false

        // WireGuard: with on-demand rules, Connect only engages isOnDemandEnabled (no
        // startVPNTunnel). Skip synthetic .starting so the toggle goes yellow immediately
        // when the current path does not match the rules.
        let onDemandOption = configManager.onDemandOptionFromConfig()
        let engageOnDemandOnly = onDemandOption != .off

        await MainActor.run {
            lastConnectionError = nil
            if !engageOnDemandOnly {
                status = .starting
            }
        }

        // Check if tunnel is already running by querying the socket
        if await socketManager.isRunning() {
            os_log("Tunnel is already running (socket responds)", log: logger, type: .info)
            await MainActor.run {
                status = .connected
                isNEConnected = true
                AlertManager.shared.showAlertDialog(
                    title: "Tunnel Already Running",
                    message:
                        "The tunnel is already running. Please disconnect it before connecting again."
                )
            }
            return
        }

        // Require an organization to be selected before connecting
        guard let currentOrg = authManager.currentOrg else {
            os_log("No organization selected, aborting connection", log: logger, type: .error)
            await failConnect(
                message: "Please select an organization before connecting.",
                alertTitle: "No Organization Selected"
            )
            return
        }

        guard let activeAccount = accountManager.activeAccount else {
            os_log("No account selected, aborting connection", log: logger, type: .error)
            await failConnect(
                message: "Please select one or re-login.",
                alertTitle: "No Account Selected"
            )
            return
        }

        // Ensure OLM credentials exist before connecting
        if let userId = authManager.currentUser?.userId {
            await authManager.ensureOlmCredentials(userId: userId)
        }

        // Ensure extension exists before connecting
        await ensureExtensionRegistered()

        guard let manager = tunnelManager else {
            await failConnect(message: "VPN configuration isn't ready.")
            return
        }

        // Ensure manager is enabled
        if !manager.isEnabled {
            manager.isEnabled = true
            do {
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            } catch {
                os_log(
                    "Error enabling manager: %{public}@", log: logger, type: .error,
                    error.localizedDescription)
            }
        }

        // Note: Go startTunnel is called from within the PacketTunnelProvider system extension
        // when the tunnel starts, not from the app side

        guard let tunnelOptions = await buildTunnelOptions() else {
            await failConnect(message: "Unable to gather tunnel configuration.")
            return
        }

        do {
            try persistTunnelStartConfig(tunnelOptions, on: manager)

            onDemandOption.apply(on: manager)

            if engageOnDemandOnly {
                // WireGuard setOnDemandEnabled(true): engage only; OS starts if rules match.
                manager.isEnabled = true
                manager.isOnDemandEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
                os_log(
                    "Connect: on-demand engaged (isOnDemandEnabled=1); OS starts if rules match",
                    log: logger, type: .info)
                await updateConnectionStatus()
            } else {
                manager.isOnDemandEnabled = false
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()

                var startOptions = tunnelOptions
                if let json = encodeTunnelOptionsAsJSONString(tunnelOptions) {
                    startOptions[Self.tunnelStartConfigJSONKey] = json as NSString
                }
                try manager.connection.startVPNTunnel(options: startOptions)
                await updateConnectionStatus()
            }
        } catch {
            os_log(
                "Error starting tunnel: %{public}@", log: logger, type: .error,
                error.localizedDescription)
            await failConnect(message: error.localizedDescription)
        }
    }

    /// Builds the options dictionary passed to the packet tunnel (and stored on
    /// `providerConfiguration` for on-demand starts). Returns nil when required
    /// account/org/fingerprint data is missing.
    private func buildTunnelOptions() async -> [String: NSObject]? {
        guard let currentOrg = authManager.currentOrg else {
            return nil
        }
        guard let activeAccount = accountManager.activeAccount else {
            return nil
        }

        var tunnelOptions: [String: NSObject] = [:]

        tunnelOptions["endpoint"] = activeAccount.hostname as NSString

        let userId = authManager.currentUser?.userId ?? activeAccount.userId
        if let olmId = secretManager.getOlmId(userId: userId) {
            tunnelOptions["id"] = olmId as NSString
        }
        if let olmSecret = secretManager.getOlmSecret(userId: userId) {
            tunnelOptions["secret"] = olmSecret as NSString
        }
        if let userToken = secretManager.getSessionToken(userId: userId) {
            tunnelOptions["userToken"] = userToken as NSString
        }

        // Required for on-demand starts; refuse incomplete configs.
        guard tunnelOptions["id"] != nil, tunnelOptions["secret"] != nil,
            tunnelOptions["userToken"] != nil
        else {
            os_log(
                "buildTunnelOptions: missing OLM credentials or session token",
                log: logger, type: .error)
            return nil
        }

        tunnelOptions["orgId"] = currentOrg.orgId as NSString

        tunnelOptions["mtu"] = NSNumber(value: configManager.getTunnelMTU())
        tunnelOptions["holepunch"] = NSNumber(value: true)
        tunnelOptions["pingIntervalSeconds"] = NSNumber(value: 5)
        tunnelOptions["pingTimeoutSeconds"] = NSNumber(value: 5)

        tunnelOptions["overrideDNS"] = NSNumber(value: configManager.getDNSOverrideEnabled())
        tunnelOptions["tunnelDNS"] = NSNumber(value: configManager.getDNSTunnelEnabled())

        var upstreamDNSServers: [String] = []
        let primaryDNS = configManager.getPrimaryDNSServer()
        if !primaryDNS.isEmpty {
            upstreamDNSServers.append("\(primaryDNS):53")
        }
        let secondaryDNS = configManager.getSecondaryDNSServer()
        if !secondaryDNS.isEmpty {
            upstreamDNSServers.append("\(secondaryDNS):53")
        }
        tunnelOptions["upstreamDNS"] = upstreamDNSServers as NSArray
        tunnelOptions["matchDomains"] = configManager.getMatchDomains() as NSArray

        #if os(macOS)
            var fingerprintPosturePair = await fingerprintManager.cachedFingerprintAndPostures()
            if fingerprintPosturePair != nil {
                os_log(
                    "Tunnel connect: using cached fingerprint/posture", log: logger, type: .info)
            } else {
                os_log(
                    "Tunnel connect: cache miss; gathering fingerprint/posture before connect",
                    log: logger, type: .info)
                await fingerprintManager.refreshCache()
                fingerprintPosturePair = await fingerprintManager.cachedFingerprintAndPostures()
            }
            guard let (fingerprint, postures) = fingerprintPosturePair else {
                os_log(
                    "Missing fingerprint/posture cache after refresh", log: logger, type: .error)
                return nil
            }
        #else
            os_log(
                "Tunnel connect: gathering fingerprint/posture on each connect (iOS, no cache)",
                log: logger, type: .info)
            let fingerprint = await fingerprintManager.gatherFingerprintInfo()
            let postures = await fingerprintManager.gatherPostureChecks()
        #endif

        if let fingerprintData = try? JSONEncoder().encode(fingerprint),
            let fingerprintDict = try? JSONSerialization.jsonObject(with: fingerprintData)
                as? [String: Any]
        {
            tunnelOptions["fingerprint"] = fingerprintDict as NSDictionary
        }

        if let posturesData = try? JSONEncoder().encode(postures),
            let posturesDict = try? JSONSerialization.jsonObject(with: posturesData)
                as? [String: Any]
        {
            tunnelOptions["postures"] = posturesDict as NSDictionary
        }

        return tunnelOptions
    }

    /// Key for the JSON start-config blob in `NETunnelProviderProtocol.providerConfiguration`.
    static let tunnelStartConfigJSONKey = "tunnelStartConfigJSON"

    private func encodeTunnelOptionsAsJSONString(_ options: [String: NSObject]) -> String? {
        var plist: [String: Any] = [:]
        for (key, value) in options {
            plist[key] = value
        }
        guard JSONSerialization.isValidJSONObject(plist),
            let data = try? JSONSerialization.data(withJSONObject: plist),
            let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    /// Writes a single plist-safe JSON string into providerConfiguration for on-demand starts.
    private func persistTunnelStartConfig(
        _ options: [String: NSObject], on manager: NETunnelProviderManager
    ) throws {
        guard let protocolConfig = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            throw NSError(
                domain: "TunnelManager", code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "VPN protocol configuration is missing"
                ])
        }
        guard let json = encodeTunnelOptionsAsJSONString(options) else {
            throw NSError(
                domain: "TunnelManager", code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to encode tunnel start config as JSON"
                ])
        }
        protocolConfig.providerConfiguration = [Self.tunnelStartConfigJSONKey: json]
        manager.protocolConfiguration = protocolConfig
        os_log(
            "Persisted tunnelStartConfigJSON (%{public}d bytes)",
            log: logger, type: .info, json.utf8.count)
    }

    /// Rebuilds and saves the on-demand start blob when Always On is configured.
    /// Call on connect (via connect path), launch, and foreground.
    func refreshProviderConfigurationIfOnDemandEnabled() async {
        guard configManager.onDemandOptionFromConfig() != .off else { return }

        await ensureExtensionRegistered()
        guard let manager = tunnelManager else {
            os_log(
                "refreshProviderConfiguration: VPN configuration isn't ready",
                log: logger, type: .info)
            return
        }

        guard let tunnelOptions = await buildTunnelOptions() else {
            os_log(
                "refreshProviderConfiguration: could not build tunnel options",
                log: logger, type: .info)
            return
        }

        do {
            try persistTunnelStartConfig(tunnelOptions, on: manager)
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            let hasBlob =
                ((manager.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerConfiguration?[Self.tunnelStartConfigJSONKey] as? String) != nil
            os_log(
                "refreshProviderConfiguration: saved blob present=%{public}d",
                log: logger, type: .info, hasBlob ? 1 : 0)
        } catch {
            os_log(
                "refreshProviderConfiguration failed: %{public}@",
                log: logger, type: .error, error.localizedDescription)
        }
    }

    /// Applies on-demand *rules* from Config (WireGuard-style). Does **not** engage
    /// `isOnDemandEnabled` — Connect does that. Persists the start-config blob when
    /// rules are non-off so a later OS start can succeed.
    /// - Parameter option: When provided, used instead of re-reading Config (avoids races
    ///   with async UI → config → apply pipelines).
    func updateOnDemandSettings(option: ActivateOnDemandOption? = nil) async {
        await ensureExtensionRegistered()

        guard let manager = tunnelManager else {
            os_log("updateOnDemandSettings: VPN configuration isn't ready", log: logger, type: .error)
            return
        }

        let onDemandOption = option ?? configManager.onDemandOptionFromConfig()
        let hasRules = onDemandOption != .off
        os_log(
            "On-demand rules: %{public}@",
            log: logger, type: .info,
            hasRules ? "saving (not engaging)" : "clearing")

        if hasRules {
            // Require a complete start blob before saving rules so Connect can engage safely.
            guard let tunnelOptions = await buildTunnelOptions() else {
                os_log(
                    "On-demand rules not saved: tunnel options unavailable (not signed in?)",
                    log: logger, type: .error)
                return
            }

            do {
                try persistTunnelStartConfig(tunnelOptions, on: manager)
            } catch {
                os_log(
                    "On-demand rules not saved: %{public}@",
                    log: logger, type: .error, error.localizedDescription)
                return
            }

            // apply() sets rules and keeps isOnDemandEnabled = (rules != nil) && existing.
            onDemandOption.apply(on: manager)
            manager.isEnabled = true
        } else {
            ActivateOnDemandOption.off.apply(on: manager)
            manager.isOnDemandEnabled = false
            manager.onDemandRules = nil
        }

        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()

            let hasBlob =
                ((manager.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerConfiguration?[Self.tunnelStartConfigJSONKey] as? String) != nil

            os_log(
                "On-demand rules saved: hasRules=%{public}d rules=%{public}d isOnDemandEnabled=%{public}d blob=%{public}d",
                log: logger, type: .info,
                hasRules ? 1 : 0,
                manager.onDemandRules?.count ?? 0,
                manager.isOnDemandEnabled ? 1 : 0,
                hasBlob ? 1 : 0)

            await updateConnectionStatus()
        } catch {
            os_log(
                "Error saving on-demand settings: %{public}@", log: logger, type: .error,
                error.localizedDescription)
        }
    }

    @MainActor
    private func failConnect(message: String, alertTitle: String? = nil) {
        lastConnectionError = message
        status = .disconnected
        if let alertTitle {
            AlertManager.shared.showAlertDialog(title: alertTitle, message: message)
        }
    }

    func disconnect() async {
        guard let manager = tunnelManager else {
            return
        }

        // Stop socket polling first
        stopSocketPolling()

        // Disable on-demand so the OS does not immediately reconnect after a manual disconnect.
        // Preference values (rules) are left intact in Config.
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            do {
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            } catch {
                os_log(
                    "Error disabling on-demand on disconnect: %{public}@", log: logger, type: .error,
                    error.localizedDescription)
            }
        }

        // Note: Go stopTunnel is called from within the PacketTunnelProvider system extension
        // when the tunnel stops, not from the app side

        manager.connection.stopVPNTunnel()
        await updateConnectionStatus()
    }

    /// Polls `status` until it reaches a terminal state (`.connected` or `.disconnected`) or
    /// `timeout` elapses, returning whatever `status` is at that point. `connect()`/`disconnect()`
    /// only kick off the underlying NE/socket work and return immediately, so callers that need
    /// the final outcome (e.g. App Intents reporting back to Shortcuts) should await this rather
    /// than reading `status` right after those calls return.
    func waitUntilSettled(timeout: TimeInterval = 15) async -> TunnelStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while status != .connected && status != .disconnected && Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return status
    }

    func switchOrg(orgId: String) async {
        // Only switch if tunnel is connected
        guard isNEConnected else {
            return
        }

        do {
            _ = try await socketManager.switchOrg(orgId: orgId)
            os_log(
                "Successfully switched to organization: %{public}@", log: logger, type: .info, orgId
            )
        } catch {
            os_log(
                "Error switching organization: %{public}@", log: logger, type: .error,
                error.localizedDescription)
        }
    }

    // MARK: - Socket Polling

    private func startSocketPolling() {
        // Stop any existing polling
        stopSocketPolling()

        guard !isPollingSocket else { return }

        isPollingSocket = true
        // Clear error alert flag when starting a new connection attempt
        hasShownErrorAlert = false

        socketPollingTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled && self.isPollingSocket {
                do {
                    // Query socket for status
                    let socketStatus = try await self.socketManager.getStatus()

                    // Check if tunnel has been terminated - if so, disconnect the network extension
                    if socketStatus.terminated {
                        os_log(
                            "Tunnel terminated, disconnecting network extension", log: self.logger,
                            type: .info)
                        await self.disconnect()
                        break
                    }

                    // Check for errors before registration - if error exists and not yet registered, disconnect and show alert
                    if let error = socketStatus.error, socketStatus.registered != true {
                        // Set flag immediately to prevent duplicate alerts (check-and-set pattern)
                        let shouldShowAlert = !hasShownErrorAlert
                        hasShownErrorAlert = true

                        // Record before disconnect so waitUntilSettled() callers see the
                        // error rather than a bare .disconnected status.
                        await MainActor.run {
                            self.lastConnectionError = error.message
                        }

                        // Stop polling immediately to prevent duplicate alerts
                        self.stopSocketPolling()

                        if shouldShowAlert {
                            os_log(
                                "Error received from socket before registration: %{public}@ - %{public}@",
                                log: self.logger,
                                type: .error,
                                error.code,
                                error.message)

                            // Show alert before disconnecting to avoid any async issues
                            await MainActor.run {
                                AlertManager.shared.showAlertDialog(
                                    title: "Connection Error",
                                    message: error.message
                                )
                            }
                        }

                        if Self.sessionExpiredSocketErrorCodes.contains(error.code) {
                            await MainActor.run {
                                self.authManager.markSessionExpiredFromConnection()
                            }
                        }

                        await self.disconnect()

                        // Immediately set status to disconnected
                        await MainActor.run {
                            self.status = .disconnected
                        }
                        break
                    }

                    // Determine the new tunnel status based on socket response
                    let newStatus: TunnelStatus
                    if socketStatus.connected && socketStatus.registered == true {
                        newStatus = .connected
                    } else {
                        newStatus = .registering
                    }

                    // Only update if status actually changed
                    let statusChanged = lastTunnelStatus != newStatus
                    let needsNEUpdate = !lastIsNEConnected

                    if statusChanged || needsNEUpdate {
                        lastTunnelStatus = newStatus
                        if needsNEUpdate {
                            lastIsNEConnected = true
                        }

                        await MainActor.run {
                            if statusChanged {
                                self.status = newStatus
                                os_log(
                                    "Tunnel status changed to: %{public}@", log: self.logger,
                                    type: .debug, newStatus.displayText)
                            }

                            if needsNEUpdate {
                                self.isNEConnected = true
                            }
                        }
                    }
                } catch {
                    // Socket not available - only update if status needs to change
                    let statusNeedsUpdate = lastTunnelStatus != .registering

                    if statusNeedsUpdate {
                        lastTunnelStatus = .registering

                        await MainActor.run {
                            // Check if VPN is still connected
                            if let manager = self.tunnelManager,
                                manager.connection.status == .connected
                            {
                                self.status = .registering
                                if !self.isNEConnected {
                                    self.isNEConnected = true
                                }
                            }
                        }
                    }
                }

                // Wait before next poll
                try? await Task.sleep(nanoseconds: UInt64(self.socketPollInterval * 1_000_000_000))
            }
        }
    }

    private func stopSocketPolling() {
        isPollingSocket = false
        socketPollingTask?.cancel()
        socketPollingTask = nil

        // Clear cached values
        lastTunnelStatus = nil
        lastIsNEConnected = false
    }

    #if os(iOS)
        @MainActor
        private func syncLiveActivity(status: TunnelStatus) {
            VPNLiveActivityManager.shared.handleStatusChange(
                status: status,
                organizationName: authManager.currentOrg?.name
            )
        }

        @MainActor
        private func reconcileLiveActivityOnLaunch() {
            VPNLiveActivityManager.shared.reconcileOnLaunch(
                status: status,
                organizationName: authManager.currentOrg?.name
            )
        }

        @MainActor
        private func syncWidgetStatus(status: TunnelStatus) {
            let organizationName =
                authManager.isAuthenticated ? authManager.currentOrg?.name : nil
            let serverHostname =
                authManager.isAuthenticated ? accountManager.activeAccount?.hostname : nil

            let statusText: String
            if hasOnDemandRules && isOnDemandEnabled && status == .disconnected {
                statusText = "On-Demand Enabled"
            } else if hasOnDemandRules && !isOnDemandEnabled && status == .disconnected {
                statusText = "On-Demand Disabled"
            } else {
                statusText = status.displayText
            }

            VPNWidgetStatusStore.write(
                statusText: statusText,
                isConnected: status == .connected,
                isBusy: status == .starting || status == .registering,
                isOnDemandEnabled: isOnDemandEnabled,
                organizationName: organizationName,
                serverHostname: serverHostname
            )
            VPNWidgetStatusStore.reloadTimelines()
        }
    #endif
}

// MARK: - OSSystemExtensionRequestDelegate
#if os(macOS)
    extension TunnelManager: OSSystemExtensionRequestDelegate {
        func request(
            _ request: OSSystemExtensionRequest,
            didFinishWithResult result: OSSystemExtensionRequest.Result
        ) {
            os_log(
                "System extension request finished with result: %d", log: logger, type: .info,
                result.rawValue)

            let success = (result == .willCompleteAfterReboot || result == .completed)

            Task { @MainActor in
                if success {
                    if result == .willCompleteAfterReboot {
                        status = .registering
                    } else {
                        status = .disconnected
                    }
                } else {
                    status = .disconnected
                }
            }

            systemExtensionInstallContinuation?.resume(returning: success)
            systemExtensionInstallContinuation = nil
            systemExtensionRequest = nil
        }

        func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
            os_log(
                "System extension request failed: %{public}@", log: logger, type: .error,
                error.localizedDescription)

            Task { @MainActor in
                status = .disconnected
            }

            systemExtensionInstallContinuation?.resume(throwing: error)
            systemExtensionInstallContinuation = nil
            systemExtensionRequest = nil
        }

        func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
            os_log(
                "System extension needs user approval - user should see System Preferences prompt",
                log: logger, type: .info)
            // The system will show a prompt to the user
            // User needs to go to System Preferences > Privacy & Security > System Extensions
            // and approve the extension
        }

        func request(
            _ request: OSSystemExtensionRequest,
            actionForReplacingExtension existing: OSSystemExtensionProperties,
            withExtension newExtension: OSSystemExtensionProperties
        ) -> OSSystemExtensionRequest.ReplacementAction {
            os_log("System extension replacement requested, replacing...", log: logger, type: .info)
            // Always replace the existing extension with the new version
            return .replace
        }
    }
#endif

extension Encodable {
    /// Converts any Encodable struct into an NSDictionary for tunnel options.
    fileprivate func asNSDict() -> NSObject {
        // Encode to JSON data
        guard let data = try? JSONEncoder().encode(self),
            let object = try? JSONSerialization.jsonObject(with: data, options: []),
            let dict = object as? NSDictionary
        else {
            // Fallback: empty dictionary if something goes wrong
            return NSDictionary()
        }
        return dict
    }
}
