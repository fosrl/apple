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
    
    private var tunnelManager: NETunnelProviderManager?
    private let bundleIdentifier = "net.pangolin.Pangolin.PacketTunnel"
    private var statusObserver: NSObjectProtocol?
    private var systemExtensionRequest: OSSystemExtensionRequest?
    private var systemExtensionInstallContinuation: CheckedContinuation<Bool, Error>?
    
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
        // Install/activate the system extension
        // Note: We can't check state beforehand, so we always try to activate
        // The delegate will handle cases where it's already activated
        os_log("Installing/activating system extension...", log: logger, type: .info)
        await MainActor.run {
            isRegistering = true
            status = .registering
        }
        
        let manager = OSSystemExtensionManager.shared
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: bundleIdentifier,
            queue: .main
        )
        request.delegate = self
        
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                systemExtensionInstallContinuation = continuation
                systemExtensionRequest = request
                manager.submitRequest(request)
            }
        } catch {
            os_log("Failed to install system extension: %{public}@", log: logger, type: .error, error.localizedDescription)
            await MainActor.run {
                status = .error
                isRegistering = false
            }
            return false
        }
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
        
        // Tunnel configuration options
        tunnelOptions["mtu"] = NSNumber(value: 1280)
        tunnelOptions["dns"] = "8.8.8.8" as NSString
        tunnelOptions["holepunch"] = NSNumber(value: false)
        tunnelOptions["pingIntervalSeconds"] = NSNumber(value: 5)
        tunnelOptions["pingTimeoutSeconds"] = NSNumber(value: 5)
        
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
    
    /// Synchronously stops the tunnel connection.
    /// This is intended for use during app termination when async operations may not complete.
    func stopTunnelSync() {
        stopSocketPolling()
        
        guard let manager = tunnelManager else {
            return
        }
        
        // Stop the VPN tunnel connection directly
        // This is a synchronous operation that will signal the network extension to stop
        manager.connection.stopVPNTunnel()
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
                    
                    await MainActor.run {
                        // Update status text based on socket response
                        // But keep isNEConnected = true as long as VPN extension is connected
                        if socketStatus.connected {
                                self.status = .connected
                        } else if socketStatus.registered == true {
                            // Registered but not connected yet
                            self.status = .registering
                        } else {
                            // Not registered yet
                            self.status = .registering
                        }
                        
                        // Keep isNEConnected = true if VPN extension is still connected
                        // This ensures the disconnect button is always available when VPN is up
                        if let manager = self.tunnelManager,
                           manager.connection.status == .connected {
                            self.isNEConnected = true
                        }
                        
                        os_log("Socket status: connected=%{public}@, registered=%{public}@, status=%{public}@", log: self.logger, type: .debug, String(socketStatus.connected), String(socketStatus.registered ?? false), socketStatus.status ?? "nil")
                    }
                } catch {
                    // Socket not available or error - check if VPN is still connected
                    // If VPN is disconnected, polling will be stopped by updateConnectionStatus
                    await MainActor.run {
                        // Only update if VPN is still connected (socket might be temporarily unavailable)
                        if let manager = self.tunnelManager,
                           manager.connection.status == .connected {
                            // VPN is connected but socket not responding - might be starting up
                            self.status = .registering
                            // Keep isNEConnected = true so user can still disconnect
                            self.isNEConnected = true
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
                 withExtension extension: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        os_log("System extension replacement requested", log: logger, type: .info)
        // Replace the existing extension
        return .replace
    }
}
