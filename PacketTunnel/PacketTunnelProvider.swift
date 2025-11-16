//
//  PacketTunnelProvider.swift
//  PacketTunnel
//
//  Created by Milo Schwartz on 11/5/25.
//

import NetworkExtension
import PangolinGo

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
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

        // Apply the settings
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                // If network settings failed, try to stop the Go tunnel
                if let stopResult = PangolinGo.stopTunnel() {
                    let stopMessage = String(cString: stopResult)
                    stopResult.deallocate()
                    print("Go stopTunnel (cleanup): \(stopMessage)")
                }
                completionHandler(error)
            } else {
                completionHandler(nil)
            }
        }
        
        // Call Go function to start tunnel (use module prefix to avoid conflict with instance method)
        var goError: Error? = nil
        if let result = PangolinGo.startTunnel() {
            let message = String(cString: result)
            result.deallocate()
            print("Go startTunnel: \(message)")
            
            // Check if the Go function returned an error
            if message.lowercased().contains("error") || message.lowercased().contains("fail") {
                goError = NSError(domain: "PangolinGo", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        } else {
            goError = NSError(domain: "PangolinGo", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to call Go startTunnel function"])
        }
        
        // If Go function failed, return error immediately
        if let error = goError {
            completionHandler(error)
            return
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // Call Go function to stop tunnel (use module prefix to avoid conflict with instance method)
        var stopError: Error? = nil
        if let result = PangolinGo.stopTunnel() {
            let message = String(cString: result)
            result.deallocate()
            print("Go stopTunnel: \(message)")
            
            // Check if the Go function returned an error
            if message.lowercased().contains("error") || message.lowercased().contains("fail") {
                stopError = NSError(domain: "PangolinGo", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        } else {
            stopError = NSError(domain: "PangolinGo", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to call Go stopTunnel function"])
        }
        
        // Log any errors but still complete (tunnel should stop regardless)
        if let error = stopError {
            print("Error stopping Go tunnel: \(error.localizedDescription)")
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

