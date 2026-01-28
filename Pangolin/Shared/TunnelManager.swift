import Combine
import Foundation
import NetworkExtension
import os.log

#if os(macOS)
    import SystemExtensions
#endif

class TunnelManager: NSObject, ObservableObject {
    @Published var isNEConnected = false
    @Published var status: TunnelStatus = .disconnected

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
        self.fingerprintManager = FingerprintManager(socketManager: self.socketManager)
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

        Task {
            #if os(macOS)
                // First, ensure system extension is installed
                let isInstalled = await installSystemExtensionIfNeeded()
                if isInstalled {
                    await ensureExtensionRegistered()
                    await updateConnectionStatus()
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
            #endif
        }
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stopSocketPolling()
    }

    @MainActor
    private func updateConnectionStatus() async {
        guard let manager = tunnelManager else {
            isNEConnected = false
            status = .disconnected
            stopSocketPolling()
            return
        }

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
            "VPN Status changed: %{public}@ (VPN status: %d)", log: logger, type: .debug,
            status.displayText, vpnStatus.rawValue)
    }

    #if os(macOS)
        private func installSystemExtensionIfNeeded() async -> Bool {
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

        // Set starting status immediately so UI shows loading state
        await MainActor.run {
            status = .starting
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
            await MainActor.run {
                status = .disconnected
                AlertManager.shared.showAlertDialog(
                    title: "No Organization Selected",
                    message: "Please select an organization before connecting."
                )
            }
            return
        }

        guard let activeAccount = accountManager.activeAccount else {
            os_log("No account selected, aborting connection", log: logger, type: .error)
            await MainActor.run {
                status = .disconnected
                AlertManager.shared.showAlertDialog(
                    title: "No Account Selected",
                    message: "Please select one or re-login."
                )
            }
            return
        }

        // Ensure OLM credentials exist before connecting
        if let userId = authManager.currentUser?.userId {
            await authManager.ensureOlmCredentials(userId: userId)
        }

        // Ensure extension exists before connecting
        await ensureExtensionRegistered()

        guard let manager = tunnelManager else {
            await MainActor.run {
                status = .disconnected
            }
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

        // Build options dictionary from config and secrets
        var tunnelOptions: [String: NSObject] = [:]

        // Get endpoint from config
        let endpoint = activeAccount.hostname
        tunnelOptions["endpoint"] = endpoint as NSString

        let userId = authManager.currentUser?.userId ?? activeAccount.userId
        // Get OLM credentials from secret manager for the current user
        if let olmId = secretManager.getOlmId(userId: userId) {
            tunnelOptions["id"] = olmId as NSString
        }
        if let olmSecret = secretManager.getOlmSecret(userId: userId) {
            tunnelOptions["secret"] = olmSecret as NSString
        }

        // Get session token from secret manager
        if let userToken = secretManager.getSessionToken(userId: userId) {
            tunnelOptions["userToken"] = userToken as NSString
        }

        // Get orgId from current organization
        tunnelOptions["orgId"] = currentOrg.orgId as NSString

        // Tunnel configuration options
        tunnelOptions["mtu"] = NSNumber(value: 1280)
        tunnelOptions["holepunch"] = NSNumber(value: true)
        tunnelOptions["pingIntervalSeconds"] = NSNumber(value: 5)
        tunnelOptions["pingTimeoutSeconds"] = NSNumber(value: 5)

        // DNS override settings from config
        let dnsOverrideEnabled = configManager.getDNSOverrideEnabled()
        tunnelOptions["overrideDNS"] = NSNumber(value: dnsOverrideEnabled)

        let dnsTunnelEnabled = configManager.getDNSTunnelEnabled()
        tunnelOptions["tunnelDNS"] = NSNumber(value: dnsTunnelEnabled)

        // Build upstream DNS servers array with :53 appended
        var upstreamDNSServers: [String] = []
        let primaryDNS = configManager.getPrimaryDNSServer()
        if !primaryDNS.isEmpty {
            upstreamDNSServers.append("\(primaryDNS):53")
        }
        let secondaryDNS = configManager.getSecondaryDNSServer()
        if !secondaryDNS.isEmpty {
            upstreamDNSServers.append("\(secondaryDNS):53")
        }
        // If no DNS servers configured, use default from config manager
        if upstreamDNSServers.isEmpty {
            let defaultDNS = configManager.getDefaultPrimaryDNS()
            upstreamDNSServers.append("\(defaultDNS):53")
        }
        tunnelOptions["upstreamDNS"] = upstreamDNSServers as NSArray

        // Set DNS to primary DNS server (or default from config manager if not configured)
        let defaultDNS = configManager.getDefaultPrimaryDNS()
        let dnsValue = primaryDNS.isEmpty ? defaultDNS : primaryDNS
        tunnelOptions["dns"] = dnsValue as NSString

        // Gather fingerprint and posture data before starting tunnel (runs off main thread)
        let fingerprint = await fingerprintManager.gatherFingerprintInfo()
        let postures = await fingerprintManager.gatherPostureChecks()
        
        // Convert Fingerprint to dictionary
        if let fingerprintData = try? JSONEncoder().encode(fingerprint),
           let fingerprintDict = try? JSONSerialization.jsonObject(with: fingerprintData) as? [String: Any] {
            tunnelOptions["fingerprint"] = fingerprintDict as NSDictionary
        }
        
        // Convert Postures to dictionary
        if let posturesData = try? JSONEncoder().encode(postures),
           let posturesDict = try? JSONSerialization.jsonObject(with: posturesData) as? [String: Any] {
            tunnelOptions["postures"] = posturesDict as NSDictionary
        }

        do {
            // Start with options
            try manager.connection.startVPNTunnel(
                options: tunnelOptions.isEmpty ? nil : tunnelOptions)

            // Update status - will transition from .starting to .registering when extension starts
            await updateConnectionStatus()

            self.fingerprintManager.start()
        } catch {
            os_log(
                "Error starting tunnel: %{public}@", log: logger, type: .error,
                error.localizedDescription)
            await MainActor.run {
                status = .disconnected
            }
        }
    }

    func disconnect() async {
        guard let manager = tunnelManager else {
            return
        }

        self.fingerprintManager.stop()

        // Stop socket polling first
        stopSocketPolling()

        // Note: Go stopTunnel is called from within the PacketTunnelProvider system extension
        // when the tunnel stops, not from the app side

        manager.connection.stopVPNTunnel()
        await updateConnectionStatus()
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
