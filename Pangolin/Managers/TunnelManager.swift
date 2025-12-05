//
//  TunnelManager.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import Foundation
import NetworkExtension
import SystemExtensions
import Combine
import os.log

class TunnelManager: NSObject, ObservableObject {
    @Published var isNEConnected = false
    @Published var status: TunnelStatus = .disconnected
    @Published var isRegistering = false
    @Published var socketStatus: SocketStatusResponse? = nil
    
    private var tunnelManager: NETunnelProviderManager?
    private let bundleIdentifier = "net.pangolin.Pangolin.PacketTunnel"
    private var statusObserver: NSObjectProtocol?
    private var systemExtensionRequest: OSSystemExtensionRequest?
    private var systemExtensionInstallContinuation: CheckedContinuation<Bool, Error>?
    
    // Version tracking for extension updates
    private let extensionVersionKey = "net.pangolin.Pangolin.PacketTunnel.lastKnownVersion"
    
    private let configManager: ConfigManager
    private let secretManager: SecretManager
    private let authManager: AuthManager
    private let socketManager: SocketManager
    
    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return OSLog(subsystem: subsystem, category: "TunnelManager")
    }()
    
    // Socket polling
    private var socketPollingTask: Task<Void, Never>?
    private let socketPollInterval: TimeInterval = 2.0 // Poll every 2 seconds
    private var isPollingSocket = false
    
    init(configManager: ConfigManager, secretManager: SecretManager, authManager: AuthManager) {
        self.configManager = configManager
        self.secretManager = secretManager
        self.authManager = authManager
        self.socketManager = SocketManager()
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
            // First, ensure system extension is installed
            let isInstalled = await installSystemExtensionIfNeeded()
            if isInstalled {
                await ensureExtensionRegistered()
                await updateConnectionStatus()
            }
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
        
        // Update status based on VPN connection status
        // If we're connected, we'll use socket status as the source of truth
        // Otherwise, use VPN status
        switch vpnStatus {
        case .invalid:
            status = .invalid
            isNEConnected = false
            stopSocketPolling()
        case .disconnected:
            status = .disconnected
            isNEConnected = false
            stopSocketPolling()
        case .connecting:
            status = .connecting
            isNEConnected = false
            stopSocketPolling()
        case .connected:
            // Once VPN extension is connected, enable disconnect button immediately
            isNEConnected = true
            // Start polling socket for actual status
            if !isPollingSocket {
                startSocketPolling()
                // Show registering status until socket polling provides actual status
                status = .registering
            }
            // If already polling, don't update status here - let socket polling handle it
        case .reasserting:
            status = .reconnecting
            isNEConnected = false
            stopSocketPolling()
        case .disconnecting:
            status = .disconnecting
            isNEConnected = false
            stopSocketPolling()
        @unknown default:
            status = .error
            isNEConnected = false
            stopSocketPolling()
        }
        
        os_log("VPN Status changed: %{public}@ (VPN status: %d)", log: logger, type: .debug, status.displayText, vpnStatus.rawValue)
    }
    
    private func installSystemExtensionIfNeeded() async -> Bool {
        os_log("Installing/activating system extension...", log: logger, type: .info)
        
        await MainActor.run {
            isRegistering = true
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
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                systemExtensionInstallContinuation = continuation
                systemExtensionRequest = request
                manager.submitRequest(request)
            }
            
            return result
        } catch {
            os_log("Failed to install system extension: %{public}@", log: logger, type: .error, error.localizedDescription)
            await MainActor.run {
                status = .error
                isRegistering = false
            }
            return false
        }
    }
    
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
        let pluginsURL = mainBundle.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        
        // Check if PlugIns directory exists
        guard FileManager.default.fileExists(atPath: pluginsURL.path) else {
            os_log("PlugIns directory does not exist at %{public}@ (this may be normal during early initialization)", log: logger, type: .debug, pluginsURL.path)
            return nil
        }
        
        // Search for the extension bundle by enumerating PlugIns directory
        guard let pluginContents = try? FileManager.default.contentsOfDirectory(at: pluginsURL, includingPropertiesForKeys: nil, options: []) else {
            os_log("Could not enumerate PlugIns directory", log: logger, type: .debug)
            return nil
        }
        
        // Find the extension bundle by checking its bundle identifier
        for pluginURL in pluginContents {
            guard pluginURL.pathExtension == "appex",
                  let extensionBundle = Bundle(url: pluginURL),
                  let pluginBundleId = extensionBundle.bundleIdentifier,
                  pluginBundleId == bundleIdentifier else {
                continue
            }
            
            // Found the extension bundle, get its version
            guard let version = extensionBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
                os_log("Could not get CFBundleVersion from extension bundle at %{public}@", log: logger, type: .error, pluginURL.path)
                return nil
            }
            
            os_log("Found extension bundle at %{public}@ with version %{public}@", log: logger, type: .debug, pluginURL.path, version)
            return version
        }
        
        os_log("Could not find PacketTunnel extension bundle with identifier %{public}@ in PlugIns directory", log: logger, type: .debug, bundleIdentifier)
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
    
    func ensureExtensionRegistered() async {
        await MainActor.run {
            isRegistering = true
        }
        
        // Load existing managers
        let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
        let existingManager = managers?.first { manager in
            guard let protocolConfig = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return protocolConfig.providerBundleIdentifier == bundleIdentifier
        }
        
        if let existing = existingManager {
            // Reload to get the actual manager instance
            do {
                try await existing.loadFromPreferences()
                await MainActor.run {
                    tunnelManager = existing
                    isRegistering = false
                }
                await updateConnectionStatus()
            } catch {
                os_log("Error loading manager: %{public}@", log: logger, type: .error, error.localizedDescription)
                await MainActor.run {
                    isRegistering = false
                }
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
        protocolConfiguration.serverAddress = "Pangolin" // Use a descriptive name, not bundle ID
        
        manager.protocolConfiguration = protocolConfiguration
        manager.localizedDescription = "Pangolin"
        manager.isEnabled = true
        
        do {
            try await manager.saveToPreferences()
            // IMPORTANT: Reload after saving to get the actual manager instance
            try await manager.loadFromPreferences()
            
            await MainActor.run {
                tunnelManager = manager
                isRegistering = false
            }
            await updateConnectionStatus()
        } catch {
            os_log("Error registering extension: %{public}@", log: logger, type: .error, error.localizedDescription)
            await MainActor.run {
                isRegistering = false
                status = .error
            }
        }
    }
    
    func connect() async {
        // Check if tunnel is already running by querying the socket
        if await socketManager.isRunning() {
            os_log("Tunnel is already running (socket responds)", log: logger, type: .info)
            await MainActor.run {
                status = .connected
                isNEConnected = true
                AlertManager.shared.showAlertDialog(
                    title: "Tunnel Already Running",
                    message: "The tunnel is already running. Please disconnect it before connecting again."
                )
            }
            return
        }
        
        // Require an organization to be selected before connecting
        guard let currentOrg = authManager.currentOrg else {
            os_log("No organization selected, aborting connection", log: logger, type: .error)
            await MainActor.run {
                AlertManager.shared.showAlertDialog(
                    title: "No Organization Selected",
                    message: "Please select an organization before connecting."
                )
            }
            return
        }
        
        // Check org access before connecting
        let hasAccess = await authManager.checkOrgAccess(orgId: currentOrg.orgId)
        if !hasAccess {
            os_log("Access denied for org %{public}@, aborting connection", log: logger, type: .error, currentOrg.orgId)
            await MainActor.run {
                AlertManager.shared.showAlertDialog(
                    title: "Access Denied",
                    message: "You do not have access to the selected organization."
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
                status = .error
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
                os_log("Error enabling manager: %{public}@", log: logger, type: .error, error.localizedDescription)
            }
        }
        
        // Note: Go startTunnel is called from within the PacketTunnelProvider system extension
        // when the tunnel starts, not from the app side
        
        // Build options dictionary from config and secrets
        var tunnelOptions: [String: NSObject] = [:]
        
        // Get endpoint from config
        let endpoint = configManager.getHostname()
        tunnelOptions["endpoint"] = endpoint as NSString
        
        // Get OLM credentials from secret manager for the current user
        if let userId = authManager.currentUser?.userId ?? configManager.config?.userId {
            if let olmId = secretManager.getOlmId(userId: userId) {
                tunnelOptions["id"] = olmId as NSString
            }
            if let olmSecret = secretManager.getOlmSecret(userId: userId) {
                tunnelOptions["secret"] = olmSecret as NSString
            }
        }
        
        // Get session token from secret manager
        if let userToken = secretManager.getSecret(key: "session-token") {
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
        
        do {
            // Start with options
            try manager.connection.startVPNTunnel(options: tunnelOptions.isEmpty ? nil : tunnelOptions)
            // Don't set isNEConnected here - let updateConnectionStatus() handle it
            await updateConnectionStatus()
        } catch {
            os_log("Error starting tunnel: %{public}@", log: logger, type: .error, error.localizedDescription)
            await MainActor.run {
                status = .error
            }
        }
    }
    
    func disconnect() async {
        guard let manager = tunnelManager else {
            return
        }
        
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
            os_log("Successfully switched to organization: %{public}@", log: logger, type: .info, orgId)
        } catch {
            os_log("Error switching organization: %{public}@", log: logger, type: .error, error.localizedDescription)
        }
    }
    
    // MARK: - Socket Polling
    
    private func startSocketPolling() {
        // Stop any existing polling
        stopSocketPolling()
        
        guard !isPollingSocket else { return }
        
        isPollingSocket = true
        
        socketPollingTask = Task { [weak self] in
            guard let self = self else { return }
            
            while !Task.isCancelled && self.isPollingSocket {
                do {
                    // Query socket for status
                    let socketStatus = try await self.socketManager.getStatus()
                    
                    // Check if tunnel has been terminated - if so, disconnect the network extension
                    if socketStatus.terminated {
                        os_log("Tunnel terminated, disconnecting network extension", log: self.logger, type: .info)
                        await self.disconnect()
                        break
                    }
                    
                    await MainActor.run {
                        // Check if socket status object has actually changed
                        let socketStatusChanged = self.socketStatus != socketStatus
                        
                        // Determine the new tunnel status based on socket response
                        let newStatus: TunnelStatus
                        if socketStatus.connected {
                            newStatus = .connected
                        } else if socketStatus.registered == true {
                            // Registered but not connected yet
                            newStatus = .registering
                        } else {
                            // Not registered yet
                            newStatus = .registering
                        }
                        
                        // Check if the computed status (what menu bar cares about) has changed
                        let computedStatusChanged = self.status != newStatus
                        
                        // Always update socketStatus for OLMStatusContentView to show full updated status
                        // Only update if it actually changed to minimize unnecessary rerenders
                        if socketStatusChanged {
                            self.socketStatus = socketStatus
                        }
                        
                        // Only update status if the computed status changed
                        if computedStatusChanged {
                            self.status = newStatus
                        }
                        
                        // Keep isNEConnected = true if VPN extension is still connected
                        // This ensures the disconnect button is always available when VPN is up
                        if let manager = self.tunnelManager,
                           manager.connection.status == .connected {
                            // Only update if it's changing
                            if !self.isNEConnected {
                                self.isNEConnected = true
                            }
                        }
                        
                        // Only log if computed status changed to reduce log noise
                        if computedStatusChanged {
                            os_log("Socket status: connected=%{public}@, registered=%{public}@, status=%{public}@, computed status changed to %{public}@", log: self.logger, type: .debug, String(socketStatus.connected), String(socketStatus.registered ?? false), socketStatus.status ?? "nil", newStatus.displayText)
                        }
                    }
                } catch {
                    // Socket not available or error - check if VPN is still connected
                    // If VPN is disconnected, polling will be stopped by updateConnectionStatus
                    await MainActor.run {
                        // Only update if socket status is changing (from non-nil to nil)
                        let hadStatus = self.socketStatus != nil
                        
                        // Only update if VPN is still connected (socket might be temporarily unavailable)
                        if let manager = self.tunnelManager,
                           manager.connection.status == .connected {
                            // VPN is connected but socket not responding - might be starting up
                            let newStatus: TunnelStatus = .registering
                            
                            // Only update if values are actually changing
                            if hadStatus {
                                self.socketStatus = nil
                            }
                            if self.status != newStatus {
                                self.status = newStatus
                            }
                            // Keep isNEConnected = true so user can still disconnect
                            if !self.isNEConnected {
                                self.isNEConnected = true
                            }
                        } else if hadStatus {
                            // VPN disconnected, clear socket status if it was set
                            self.socketStatus = nil
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
        
        // Clear socket status when polling stops
        socketStatus = nil
    }
}

// MARK: - OSSystemExtensionRequestDelegate
extension TunnelManager: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        os_log("System extension request finished with result: %d", log: logger, type: .info, result.rawValue)
        
        let success = (result == .willCompleteAfterReboot || result == .completed)
        
        Task { @MainActor in
            if success {
                if result == .willCompleteAfterReboot {
                    status = .registering
                } else {
                    status = .disconnected
                }
            } else {
                status = .error
            }
            isRegistering = false
        }
        
        systemExtensionInstallContinuation?.resume(returning: success)
        systemExtensionInstallContinuation = nil
        systemExtensionRequest = nil
    }
    
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        os_log("System extension request failed: %{public}@", log: logger, type: .error, error.localizedDescription)
        
        Task { @MainActor in
            status = .error
            isRegistering = false
        }
        
        systemExtensionInstallContinuation?.resume(throwing: error)
        systemExtensionInstallContinuation = nil
        systemExtensionRequest = nil
    }
    
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        os_log("System extension needs user approval - user should see System Preferences prompt", log: logger, type: .info)
        // The system will show a prompt to the user
        // User needs to go to System Preferences > Privacy & Security > System Extensions
        // and approve the extension
    }
    
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension newExtension: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        os_log("System extension replacement requested, replacing...", log: logger, type: .info)
        // Always replace the existing extension with the new version
        return .replace
    }
}
