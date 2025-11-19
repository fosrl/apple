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

class TunnelManager: NSObject, ObservableObject {
    @Published var isConnected = false
    @Published var statusText = "Disconnected"
    @Published var isRegistering = false
    
    private var tunnelManager: NETunnelProviderManager?
    private let bundleIdentifier = "net.pangolin.Pangolin.PacketTunnel"
    private var statusObserver: NSObjectProtocol?
    private var systemExtensionRequest: OSSystemExtensionRequest?
    private var systemExtensionInstallContinuation: CheckedContinuation<Bool, Error>?
    
    private let configManager: ConfigManager
    private let secretManager: SecretManager
    private let authManager: AuthManager
    
    init(configManager: ConfigManager, secretManager: SecretManager, authManager: AuthManager) {
        self.configManager = configManager
        self.secretManager = secretManager
        self.authManager = authManager
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
    }
    
    @MainActor
    private func updateConnectionStatus() async {
        guard let manager = tunnelManager else {
            isConnected = false
            statusText = "Disconnected"
            return
        }
        
        let status = manager.connection.status
        isConnected = (status == .connected)
        
        switch status {
        case .invalid:
            statusText = "Invalid"
        case .disconnected:
            statusText = "Disconnected"
        case .connecting:
            statusText = "Connecting..."
        case .connected:
            statusText = "Connected"
        case .reasserting:
            statusText = "Reconnecting..."
        case .disconnecting:
            statusText = "Disconnecting..."
        @unknown default:
            statusText = "Unknown"
        }
        
        print("VPN Status changed: \(statusText) (status: \(status.rawValue))")
    }
    
    private func installSystemExtensionIfNeeded() async -> Bool {
        // Install/activate the system extension
        // Note: We can't check state beforehand, so we always try to activate
        // The delegate will handle cases where it's already activated
        print("Installing/activating system extension...")
        await MainActor.run {
            isRegistering = true
            statusText = "Installing system extension..."
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
            print("Failed to install system extension: \(error)")
            await MainActor.run {
                statusText = "Error: \(error.localizedDescription)"
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
                print("Error loading manager: \(error)")
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
            print("Error registering extension: \(error)")
            await MainActor.run {
                isRegistering = false
                statusText = "Error: \(error.localizedDescription)"
            }
        }
    }
    
    func connect() async {
        // Ensure extension exists before connecting
        await ensureExtensionRegistered()
        
        guard let manager = tunnelManager else {
            await MainActor.run {
                statusText = "Error: Extension not available"
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
                print("Error enabling manager: \(error)")
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
        
        // Tunnel configuration options
        tunnelOptions["mtu"] = NSNumber(value: 1280)
        tunnelOptions["dns"] = "8.8.8.8" as NSString
        tunnelOptions["holepunch"] = NSNumber(value: false)
        tunnelOptions["pingIntervalSeconds"] = NSNumber(value: 5)
        tunnelOptions["pingTimeoutSeconds"] = NSNumber(value: 5)
        
        do {
            // Start with options
            try manager.connection.startVPNTunnel(options: tunnelOptions.isEmpty ? nil : tunnelOptions)
            // Don't set isConnected here - let updateConnectionStatus() handle it
            await updateConnectionStatus()
        } catch {
            print("Error starting tunnel: \(error)")
            await MainActor.run {
                statusText = "Error: \(error.localizedDescription)"
            }
        }
    }
    
    func disconnect() async {
        guard let manager = tunnelManager else {
            return
        }
        
        // Note: Go stopTunnel is called from within the PacketTunnelProvider system extension
        // when the tunnel stops, not from the app side
        
        manager.connection.stopVPNTunnel()
        await updateConnectionStatus()
    }
    
    /// Synchronously stops the tunnel connection.
    /// This is intended for use during app termination when async operations may not complete.
    func stopTunnelSync() {
        guard let manager = tunnelManager else {
            return
        }
        
        // Stop the VPN tunnel connection directly
        // This is a synchronous operation that will signal the network extension to stop
        manager.connection.stopVPNTunnel()
    }
}

// MARK: - OSSystemExtensionRequestDelegate
extension TunnelManager: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        print("System extension request finished with result: \(result.rawValue)")
        
        let success = (result == .willCompleteAfterReboot || result == .completed)
        
        Task { @MainActor in
            if success {
                if result == .willCompleteAfterReboot {
                    statusText = "System extension will be installed after reboot"
                } else {
                    statusText = "System extension installed"
                }
            } else {
                statusText = "System extension installation failed"
            }
            isRegistering = false
        }
        
        systemExtensionInstallContinuation?.resume(returning: success)
        systemExtensionInstallContinuation = nil
        systemExtensionRequest = nil
    }
    
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        print("System extension request failed: \(error.localizedDescription)")
        
        Task { @MainActor in
            statusText = "Error: \(error.localizedDescription)"
            isRegistering = false
        }
        
        systemExtensionInstallContinuation?.resume(throwing: error)
        systemExtensionInstallContinuation = nil
        systemExtensionRequest = nil
    }
    
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        print("System extension needs user approval - user should see System Preferences prompt")
        // The system will show a prompt to the user
        // User needs to go to System Preferences > Privacy & Security > System Extensions
        // and approve the extension
    }
    
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension extension: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        print("System extension replacement requested")
        // Replace the existing extension
        return .replace
    }
}

