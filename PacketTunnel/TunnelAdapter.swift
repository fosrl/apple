//
//  TunnelAdapter.swift
//  PacketTunnel
//
//  Created by Milo Schwartz on 11/5/25.
//

import Foundation
import NetworkExtension
import PangolinGo
import os.log

/// Adapter class that handles tunnel file descriptor discovery and management
public class TunnelAdapter {
    private weak var packetTunnelProvider: NEPacketTunnelProvider?
    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin.PacketTunnel"
        return OSLog(subsystem: subsystem, category: "TunnelAdapter")
    }()
    
    public init(with packetTunnelProvider: NEPacketTunnelProvider) {
        self.packetTunnelProvider = packetTunnelProvider
    }
    
    /// Discovers the tunnel file descriptor by scanning open file descriptors
    /// and matching them against the utun control interface.
    ///
    /// - Returns: The file descriptor for the tunnel interface, or nil if not found
    private func discoverTunnelFileDescriptor() -> Int32? {
        os_log("Starting tunnel file descriptor discovery", log: logger, type: .info)
        
        var ctlInfo = ctl_info()
        
        // Set up the control info structure with the utun control name
        withUnsafeMutablePointer(to: &ctlInfo.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
                _ = strcpy($0, "com.apple.net.utun_control")
            }
        }
        
        // Scan file descriptors from 0 to 1024
        // Note: This is a heuristic - the actual FD could be outside this range
        for fd: Int32 in 0...1024 {
            var addr = sockaddr_ctl()
            var ret: Int32 = -1
            var len = socklen_t(MemoryLayout.size(ofValue: addr))
            
            // Get the peer name for this file descriptor
            withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    ret = getpeername(fd, $0, &len)
                }
            }
            
            // Skip if getpeername failed or it's not a system control socket
            if ret != 0 || addr.sc_family != AF_SYSTEM {
                continue
            }
            
            // Get the control ID if we haven't already
            if ctlInfo.ctl_id == 0 {
                ret = ioctl(fd, CTLIOCGINFO, &ctlInfo)
                if ret != 0 {
                    continue
                }
            }
            
            // Match the control ID to find our tunnel interface
            if addr.sc_id == ctlInfo.ctl_id {
                os_log("Discovered tunnel file descriptor: %d", log: logger, type: .info, fd)
                return fd
            }
        }
        
        os_log("Could not discover tunnel file descriptor after scanning 0-1024", log: logger, type: .default)
        return nil
    }
    
    /// Starts the tunnel with the provided network settings and discovers the file descriptor
    ///
    /// - Parameters:
    ///   - networkSettings: The network settings to apply to the tunnel
    ///   - completionHandler: Called when the tunnel startup is complete or fails
    public func start(with networkSettings: NEPacketTunnelNetworkSettings,
                     completionHandler: @escaping (Error?) -> Void) {
        os_log("Starting tunnel with network settings", log: logger, type: .info)
        
        // Set network settings first - this creates the tunnel interface
        packetTunnelProvider?.setTunnelNetworkSettings(networkSettings) { [weak self] error in
            guard let self = self else {
                let adapterError = NSError(domain: "TunnelAdapter", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Adapter deallocated"])
                os_log("Adapter deallocated during tunnel start", log: self?.logger ?? .default, type: .fault)
                completionHandler(adapterError)
                return
            }
            
            if let error = error {
                os_log("Failed to set tunnel network settings: %{public}@", log: self.logger, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }
            
            os_log("Tunnel network settings applied successfully", log: self.logger, type: .info)
            
            // Now that network settings are set, discover the file descriptor
            let tunnelFD: Int32
            if let discoveredFD = self.discoverTunnelFileDescriptor() {
                tunnelFD = discoveredFD
                os_log("Tunnel file descriptor discovered: %d", log: self.logger, type: .info, tunnelFD)
            } else {
                // Log warning but use 0 as sentinel value - the tunnel might still work
                tunnelFD = 0
                os_log("Warning: Could not discover tunnel file descriptor, using 0", log: self.logger, type: .default)
            }
            
            // Call Go function to start tunnel with file descriptor
            os_log("Calling Go startTunnel function with FD: %d", log: self.logger, type: .info, tunnelFD)
            var goError: Error? = nil
            if let result = PangolinGo.startTunnel(tunnelFD) {
                let message = String(cString: result)
                result.deallocate()
                os_log("Go startTunnel returned: %{public}@", log: self.logger, type: .info, message)
                
                // Check if the Go function returned an error
                if message.lowercased().contains("error") || message.lowercased().contains("fail") {
                    goError = NSError(domain: "PangolinGo", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
                    os_log("Go tunnel start failed: %{public}@", log: self.logger, type: .error, message)
                }
            } else {
                goError = NSError(domain: "PangolinGo", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to call Go startTunnel function"])
                os_log("Failed to call Go startTunnel function (returned nil)", log: self.logger, type: .error)
            }
            
            // If Go function failed, return error
            if let error = goError {
                // Try to stop the Go tunnel on error
                os_log("Stopping Go tunnel due to start error", log: self.logger, type: .info)
                _ = self.stopGoTunnel()
                completionHandler(error)
                return
            }
            
            os_log("Tunnel started successfully", log: self.logger, type: .info)
            completionHandler(nil)
        }
    }
    
    /// Stops the Go tunnel
    ///
    /// - Returns: An error if stopping failed, nil otherwise
    public func stop() -> Error? {
        return stopGoTunnel()
    }
    
    /// Internal method to stop the Go tunnel
    private func stopGoTunnel() -> Error? {
        os_log("Stopping Go tunnel", log: logger, type: .info)
        var stopError: Error? = nil
        if let result = PangolinGo.stopTunnel() {
            let message = String(cString: result)
            result.deallocate()
            os_log("Go stopTunnel returned: %{public}@", log: logger, type: .info, message)
            
            // Check if the Go function returned an error
            if message.lowercased().contains("error") || message.lowercased().contains("fail") {
                stopError = NSError(domain: "PangolinGo", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        } else {
            stopError = NSError(domain: "PangolinGo", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to call Go stopTunnel function"])
            os_log("Failed to call Go stopTunnel function (returned nil)", log: logger, type: .error)
        }
        
        // Log any errors but don't fail (tunnel should stop regardless)
        if let error = stopError {
            os_log("Error stopping Go tunnel: %{public}@", log: logger, type: .error, error.localizedDescription)
        } else {
            os_log("Go tunnel stopped successfully", log: logger, type: .info)
        }
        
        return stopError
    }
}

