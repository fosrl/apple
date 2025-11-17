//
//  PacketTunnelProvider.swift
//  PacketTunnel
//
//  Created by Milo Schwartz on 11/5/25.
//

import NetworkExtension
import os.log

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var tunnelAdapter: TunnelAdapter?
    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin.PacketTunnel"
        let log = OSLog(subsystem: subsystem, category: "PacketTunnelProvider")
        // Log the subsystem being used for debugging
        os_log("PacketTunnelProvider initialized with subsystem: %{public}@", log: log, type: .debug, subsystem)
        return log
    }()
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("startTunnel called with options: %{public}@", log: logger, type: .debug, options?.description ?? "nil")
        
        // Initialize the tunnel adapter
        tunnelAdapter = TunnelAdapter(with: self)
        
        // Set up a basic network configuration
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        // Configure IPv4 settings
        let ipv4Settings = NEIPv4Settings(addresses: ["10.0.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings

        // Set DNS settings
        let dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
        settings.dnsSettings = dnsSettings

        // Set MTU
        settings.mtu = 1500

        os_log("Network settings configured - IPv4: %{public}@, DNS: %{public}@, MTU: %d", 
               log: logger, type: .debug,
               settings.ipv4Settings?.addresses.joined(separator: ", ") ?? "none",
               settings.dnsSettings?.servers.joined(separator: ", ") ?? "none",
               settings.mtu ?? 0)

        // Use the tunnel adapter to start the tunnel and discover the file descriptor
        tunnelAdapter?.start(with: settings) { [weak self] (error: Error?) in
            if let error = error {
                os_log("Tunnel start failed: %{public}@", log: self?.logger ?? .default, type: .error, error.localizedDescription)
            } else {
                os_log("Tunnel start completed successfully", log: self?.logger ?? .default, type: .info)
            }
            completionHandler(error)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("stopTunnel called with reason: %d", log: logger, type: .debug, reason.rawValue)
        
        // Use the tunnel adapter to stop the Go tunnel
        if let error = tunnelAdapter?.stop() {
            os_log("Error stopping tunnel adapter: %{public}@", log: logger, type: .error, error.localizedDescription)
        } else {
            os_log("Tunnel stopped successfully", log: logger, type: .info)
        }
        
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Handle messages from the app if needed
        completionHandler?(nil)
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        // Handle sleep if needed
        completionHandler()
    }
    
    override func wake() {
        // Handle wake if needed
    }
}

