//
//  TunnelAdapter.swift
//  PacketTunnel
//
//  Created by Milo Schwartz on 11/5/25.
//

import Darwin
import Foundation
import NetworkExtension
import PangolinGo
import os.log

#if os(iOS)
    import UIKit
#endif

// Centralized log level configuration
enum LogLevel: Int {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3
}

// NetworkSettingsJSON represents the JSON structure from Go
private struct NetworkSettingsJSON: Codable {
    let tunnelRemoteAddress: String?
    let mtu: Int?
    let dnsServers: [String]?
    let ipv4Addresses: [String]?
    let ipv4SubnetMasks: [String]?
    let ipv4IncludedRoutes: [IPv4RouteJSON]?
    let ipv4ExcludedRoutes: [IPv4RouteJSON]?
    let ipv6Addresses: [String]?
    let ipv6NetworkPrefixes: [String]?
    let ipv6IncludedRoutes: [IPv6RouteJSON]?
    let ipv6ExcludedRoutes: [IPv6RouteJSON]?

    enum CodingKeys: String, CodingKey {
        case tunnelRemoteAddress = "tunnel_remote_address"
        case mtu
        case dnsServers = "dns_servers"
        case ipv4Addresses = "ipv4_addresses"
        case ipv4SubnetMasks = "ipv4_subnet_masks"
        case ipv4IncludedRoutes = "ipv4_included_routes"
        case ipv4ExcludedRoutes = "ipv4_excluded_routes"
        case ipv6Addresses = "ipv6_addresses"
        case ipv6NetworkPrefixes = "ipv6_network_prefixes"
        case ipv6IncludedRoutes = "ipv6_included_routes"
        case ipv6ExcludedRoutes = "ipv6_excluded_routes"
    }
}

private struct IPv4RouteJSON: Codable {
    let destinationAddress: String
    let subnetMask: String?
    let gatewayAddress: String?
    let isDefault: Bool?

    enum CodingKeys: String, CodingKey {
        case destinationAddress = "destination_address"
        case subnetMask = "subnet_mask"
        case gatewayAddress = "gateway_address"
        case isDefault = "is_default"
    }
}

private struct IPv6RouteJSON: Codable {
    let destinationAddress: String
    let networkPrefixLength: Int?
    let gatewayAddress: String?
    let isDefault: Bool?

    enum CodingKeys: String, CodingKey {
        case destinationAddress = "destination_address"
        case networkPrefixLength = "network_prefix_length"
        case gatewayAddress = "gateway_address"
        case isDefault = "is_default"
    }
}

// Adapter class that handles tunnel file descriptor discovery and management
public class TunnelAdapter {
    private weak var packetTunnelProvider: NEPacketTunnelProvider?
    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin.PacketTunnel"
        return OSLog(subsystem: subsystem, category: "TunnelAdapter")
    }()

    private var lastAppliedSettings: NEPacketTunnelNetworkSettings?
    private var lastSeenVersion: Int = -1
    private var settingsPollTimer: DispatchSourceTimer?
    private let pollInterval: TimeInterval = 0.5  // 500ms
    private var overrideDNS: Bool = false
    public init(with packetTunnelProvider: NEPacketTunnelProvider) {
        self.packetTunnelProvider = packetTunnelProvider
        // Set log level for Go logger to debug
        PangolinGo.setLogLevel(Int32(LogLevel.debug.rawValue))

        // Get app version from bundle (semver)
        let appVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        #if os(iOS)
            let agent: String
            if UIDevice.current.userInterfaceIdiom == .pad {
                agent = "Pangolin iPadOS"
            } else {
                agent = "Pangolin iOS"
            }
        #else
            let agent = "Pangolin macOS"
        #endif

        // Use the shared function to get the platform-appropriate socket path
        let socketPath = getSocketPath()

        // OLM initialization configuration with version and agent from Swift
        let config: [String: Any] = [
            "enableAPI": true,
            "socketPath": socketPath,
            "logLevel": "debug",
            "version": appVersion,
            "agent": agent,
        ]

        // Convert config to JSON string
        guard let jsonData = try? JSONSerialization.data(withJSONObject: config),
            let configJSON = String(data: jsonData, encoding: .utf8)
        else {
            os_log("Failed to serialize init config to JSON", log: logger, type: .error)
            return
        }

        // Create a mutable C string copy for the Go function
        let configJSONCString = configJSON.utf8CString
        let configJSONPtr = UnsafeMutablePointer<CChar>.allocate(capacity: configJSONCString.count)
        configJSONCString.withUnsafeBufferPointer { buffer in
            configJSONPtr.initialize(from: buffer.baseAddress!, count: buffer.count)
        }
        defer {
            configJSONPtr.deallocate()
        }

        // Call Go initOlm function with JSON configuration
        if let result = PangolinGo.initOlm(configJSONPtr) {
            let message = String(cString: result)
            result.deallocate()
            os_log("Go init returned: %{public}@", log: logger, type: .debug, message)

            // Check if the Go function returned an error
            if message.lowercased().contains("error") || message.lowercased().contains("fail") {
                os_log("Go init failed: %{public}@", log: logger, type: .error, message)
            }
        } else {
            os_log("Failed to call Go init function (returned nil)", log: logger, type: .error)
        }
    }

    // Discovers the tunnel file descriptor
    // Scans open file descriptors and matches them against the utun control interface
    // Works on both macOS and iOS
    //
    // - Returns: The file descriptor for the tunnel interface, or nil if not found
    private func discoverTunnelFileDescriptor() -> Int32? {
        os_log("discoverTunnelFileDescriptor() called", log: logger, type: .info)
        os_log("Starting tunnel file descriptor discovery", log: logger, type: .info)

        // Scan file descriptors using system extension APIs
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
                os_log("Discovered tunnel file descriptor: %d", log: logger, type: .debug, fd)
                return fd
            }
        }

        os_log(
            "Could not discover tunnel file descriptor after scanning 0-1024", log: logger,
            type: .default)
        return nil
    }

    // Starts the tunnel and discovers the file descriptor
    //
    // - Parameters:
    //   - options: Required dictionary containing tunnel configuration (endpoint, id, secret, mtu, dns, holepunch, pingIntervalSeconds, pingTimeoutSeconds)
    //   - completionHandler: Called when the tunnel startup is complete or fails
    public func start(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("Starting tunnel", log: logger, type: .debug)

        // Discover the file descriptor
        let tunnelFD: Int32
        if let discoveredFD = discoverTunnelFileDescriptor() {
            tunnelFD = discoveredFD
            os_log("Tunnel file descriptor discovered: %d", log: logger, type: .debug, tunnelFD)
        } else {
            // Log warning but use 0 as sentinel value - the tunnel might still work
            tunnelFD = 0
            os_log(
                "Warning: Could not discover tunnel file descriptor, using 0", log: logger,
                type: .default)
        }

        // Get values from options (passed through from TunnelManager)
        guard let options = options else {
            let error = NSError(
                domain: "TunnelAdapter", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Options are required"])
            os_log("Options are required but were nil", log: logger, type: .error)
            completionHandler(error)
            return
        }

        guard let endpoint = options["endpoint"] as? String,
            let id = options["id"] as? String,
            let secret = options["secret"] as? String,
            let mtu = (options["mtu"] as? NSNumber)?.intValue,
            let dns = options["dns"] as? String,
            let holepunch = (options["holepunch"] as? NSNumber)?.boolValue,
            let pingIntervalSeconds = (options["pingIntervalSeconds"] as? NSNumber)?.intValue,
            let userToken: String = options["userToken"] as? String,
            let orgId = options["orgId"] as? String,
            let upstreamDNS = options["upstreamDNS"] as? [String],
            let overrideDNSValue = (options["overrideDNS"] as? NSNumber)?.boolValue,
            let tunnelDNS = (options["tunnelDNS"] as? NSNumber)?.boolValue,
            let pingTimeoutSeconds = (options["pingTimeoutSeconds"] as? NSNumber)?.intValue,
            let fingerprint = (options["fingerprint"]) as? [String: Any],
            let postures = (options["postures"]) as? [String: Any]
        else {
            let error = NSError(
                domain: "TunnelAdapter", code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Required tunnel configuration options are missing"
                ])
            os_log("Required tunnel configuration options are missing", log: logger, type: .error)
            completionHandler(error)
            return
        }

        // Tunnel configuration
        let config: [String: Any] = [
            "endpoint": endpoint,
            "id": id,
            "secret": secret,
            "mtu": mtu,
            "dns": dns,
            "holepunch": holepunch,
            "pingIntervalSeconds": pingIntervalSeconds,
            "pingTimeoutSeconds": pingTimeoutSeconds,
            "userToken": userToken,
            "orgId": orgId,
            "upstreamDNS": upstreamDNS,
            "overrideDNS": overrideDNSValue,
            "tunnelDNS": tunnelDNS,
            "fingerprint": fingerprint,
            "postures": postures,
        ]

        self.overrideDNS = overrideDNSValue

        // Convert config to JSON string
        guard let jsonData = try? JSONSerialization.data(withJSONObject: config),
            let configJSON = String(data: jsonData, encoding: .utf8)
        else {
            let error = NSError(
                domain: "PangolinGo", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to serialize tunnel config to JSON"])
            os_log("Failed to serialize tunnel config to JSON", log: logger, type: .error)
            completionHandler(error)
            return
        }

        // Call Go function to start tunnel with file descriptor and JSON configuration
        os_log("Calling Go startTunnel function with FD: %d", log: logger, type: .debug, tunnelFD)
        var goError: Error? = nil

        // Create a mutable C string copy for the Go function
        let configJSONCString = configJSON.utf8CString
        let configJSONPtr = UnsafeMutablePointer<CChar>.allocate(capacity: configJSONCString.count)
        configJSONCString.withUnsafeBufferPointer { buffer in
            configJSONPtr.initialize(from: buffer.baseAddress!, count: buffer.count)
        }
        defer {
            configJSONPtr.deallocate()
        }

        if let result = PangolinGo.startTunnel(tunnelFD, configJSONPtr) {
            let message = String(cString: result)
            result.deallocate()
            os_log("Go startTunnel returned: %{public}@", log: logger, type: .debug, message)

            // Check if the Go function returned an error
            if message.lowercased().contains("error") || message.lowercased().contains("fail") {
                goError = NSError(
                    domain: "PangolinGo", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
                os_log("Go tunnel start failed: %{public}@", log: logger, type: .error, message)
            }
        } else {
            goError = NSError(
                domain: "PangolinGo", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to call Go startTunnel function"])
            os_log(
                "Failed to call Go startTunnel function (returned nil)", log: logger, type: .error)
        }

        // If Go function failed, return error
        if let error = goError {
            // Try to stop the Go tunnel on error
            os_log("Stopping Go tunnel due to start error", log: logger, type: .debug)
            _ = stopGoTunnel()
            completionHandler(error)
            return
        }

        os_log("Tunnel started successfully", log: logger, type: .debug)

        // Initialize version tracking
        lastSeenVersion = PangolinGo.getNetworkSettingsVersion()

        // Start polling for network settings updates
        startSettingsPolling()

        completionHandler(nil)
    }

    // Stops the Go tunnel
    //
    // - Returns: An error if stopping failed, nil otherwise
    public func stop() -> Error? {
        stopSettingsPolling()
        return stopGoTunnel()
    }

    // Internal method to stop the Go tunnel
    private func stopGoTunnel() -> Error? {
        os_log("Stopping Go tunnel", log: logger, type: .debug)
        var stopError: Error? = nil
        if let result = PangolinGo.stopTunnel() {
            let message = String(cString: result)
            result.deallocate()
            os_log("Go stopTunnel returned: %{public}@", log: logger, type: .debug, message)

            // Check if the Go function returned an error
            if message.lowercased().contains("error") || message.lowercased().contains("fail") {
                stopError = NSError(
                    domain: "PangolinGo", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        } else {
            stopError = NSError(
                domain: "PangolinGo", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to call Go stopTunnel function"])
            os_log(
                "Failed to call Go stopTunnel function (returned nil)", log: logger, type: .error)
        }

        // Log any errors but don't fail (tunnel should stop regardless)
        if let error = stopError {
            os_log(
                "Error stopping Go tunnel: %{public}@", log: logger, type: .error,
                error.localizedDescription)
        } else {
            os_log("Go tunnel stopped successfully", log: logger, type: .debug)
        }

        os_log("Tunnel stopped successfully", log: self.logger, type: .debug)

        return stopError
    }

    // MARK: - Network Settings Polling

    private func startSettingsPolling() {
        stopSettingsPolling()  // Stop any existing timer

        os_log(
            "Starting network settings polling (interval: %.1f seconds)", log: logger, type: .debug,
            pollInterval)

        let queue = DispatchQueue(label: "com.pangolin.tunnel.settings-poll", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.pollNetworkSettings()
        }
        timer.resume()
        settingsPollTimer = timer
    }

    private func stopSettingsPolling() {
        if let timer = settingsPollTimer {
            timer.cancel()
            settingsPollTimer = nil
            os_log("Stopped network settings polling", log: logger, type: .debug)
        }
    }

    private func pollNetworkSettings() {
        // Poll the version number first (lightweight)
        let currentVersion = PangolinGo.getNetworkSettingsVersion()

        // Only fetch full settings if version has changed
        if currentVersion > lastSeenVersion {
            os_log(
                "Network settings version changed from %d to %d, fetching settings", log: logger,
                type: .debug, lastSeenVersion, currentVersion)
            lastSeenVersion = currentVersion

            // Fetch the full network settings
            guard let result = PangolinGo.getNetworkSettings() else {
                os_log("getNetworkSettings returned nil", log: logger, type: .error)
                return
            }

            let jsonString = String(cString: result)
            result.deallocate()

            // Parse JSON
            guard let jsonData = jsonString.data(using: .utf8) else {
                os_log("Failed to convert JSON string to data", log: logger, type: .error)
                return
            }

            let decoder = JSONDecoder()
            guard let settingsJSON = try? decoder.decode(NetworkSettingsJSON.self, from: jsonData)
            else {
                // Empty JSON is valid (no settings)
                if jsonString.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" {
                    return
                }
                os_log(
                    "Failed to decode network settings JSON: %{public}@", log: logger, type: .error,
                    jsonString)
                return
            }

            // Convert to NEPacketTunnelNetworkSettings, merging with existing settings
            guard
                let newSettings = convertJSONToNetworkSettings(
                    settingsJSON, mergingWith: lastAppliedSettings)
            else {
                return
            }

            // Version changed, so settings are different - update them
            os_log("Network settings version changed, updating...", log: logger, type: .debug)
            updateNetworkSettings(newSettings)
        }
    }

    private func convertJSONToNetworkSettings(
        _ json: NetworkSettingsJSON, mergingWith existing: NEPacketTunnelNetworkSettings?
    ) -> NEPacketTunnelNetworkSettings? {
        // If all fields are nil/empty, return nil (no settings to apply)
        let hasSettings =
            json.tunnelRemoteAddress != nil || json.mtu != nil
            || (json.dnsServers != nil && !json.dnsServers!.isEmpty)
            || (json.ipv4Addresses != nil && !json.ipv4Addresses!.isEmpty)
            || (json.ipv6Addresses != nil && !json.ipv6Addresses!.isEmpty)

        if !hasSettings {
            return nil
        }

        // Use existing remote address if not specified in JSON, otherwise use JSON value or default
        let remoteAddress = json.tunnelRemoteAddress ?? existing?.tunnelRemoteAddress ?? "127.0.0.1"
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)

        // Set MTU (use JSON value if provided, otherwise preserve existing)
        if let mtu = json.mtu {
            settings.mtu = NSNumber(value: mtu)
        } else if let existingMTU = existing?.mtu {
            settings.mtu = existingMTU
        }

        // Set DNS settings (use JSON value if provided, otherwise preserve existing)
        if let dnsServers = json.dnsServers, !dnsServers.isEmpty {
            let dnsSettings = NEDNSSettings(servers: dnsServers)
            // Set search domains to empty array to match all domains only if overrideDNS is enabled
            if overrideDNS {
                dnsSettings.matchDomains = [""]
            }
            settings.dnsSettings = dnsSettings
        } else if let existingDNS = existing?.dnsSettings {
            // Only modify matchDomains if overrideDNS is enabled
            if overrideDNS {
                existingDNS.matchDomains = [""]
            }
            settings.dnsSettings = existingDNS
        }

        // Set IPv4 settings
        if let ipv4Addresses = json.ipv4Addresses, !ipv4Addresses.isEmpty {
            // Log raw values from JSON before creating settings
            let subnetMasks =
                json.ipv4SubnetMasks
                ?? Array(repeating: "255.255.255.0", count: ipv4Addresses.count)

            let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: subnetMasks)

            // Convert routes
            var includedRoutes: [NEIPv4Route] = []
            if let routesJSON = json.ipv4IncludedRoutes {
                for routeJSON in routesJSON {
                    if routeJSON.isDefault == true {
                        includedRoutes.append(NEIPv4Route.default())
                    } else {
                        let destination = routeJSON.destinationAddress
                        let subnetMask = routeJSON.subnetMask ?? "255.255.255.255"
                        let route = NEIPv4Route(
                            destinationAddress: destination, subnetMask: subnetMask)
                        if let gateway = routeJSON.gatewayAddress {
                            route.gatewayAddress = gateway
                        }
                        includedRoutes.append(route)
                    }
                }
            }
            ipv4Settings.includedRoutes = includedRoutes

            var excludedRoutes: [NEIPv4Route] = []
            if let routesJSON = json.ipv4ExcludedRoutes {
                for routeJSON in routesJSON {
                    if routeJSON.isDefault == true {
                        excludedRoutes.append(NEIPv4Route.default())
                    } else {
                        let destination = routeJSON.destinationAddress
                        let subnetMask = routeJSON.subnetMask ?? "255.255.255.255"
                        let route = NEIPv4Route(
                            destinationAddress: destination, subnetMask: subnetMask)
                        if let gateway = routeJSON.gatewayAddress {
                            route.gatewayAddress = gateway
                        }
                        excludedRoutes.append(route)
                    }
                }
            }
            ipv4Settings.excludedRoutes = excludedRoutes
            settings.ipv4Settings = ipv4Settings
        }

        // Set IPv6 settings
        if let ipv6Addresses = json.ipv6Addresses, !ipv6Addresses.isEmpty {
            let networkPrefixes =
                json.ipv6NetworkPrefixes ?? Array(repeating: "64", count: ipv6Addresses.count)
            let networkPrefixLengths = networkPrefixes.compactMap { Int($0) }.map {
                NSNumber(value: $0)
            }
            let ipv6Settings = NEIPv6Settings(
                addresses: ipv6Addresses, networkPrefixLengths: networkPrefixLengths)

            // Convert routes
            var includedRoutes: [NEIPv6Route] = []
            if let routesJSON = json.ipv6IncludedRoutes {
                for routeJSON in routesJSON {
                    if routeJSON.isDefault == true {
                        includedRoutes.append(NEIPv6Route.default())
                    } else {
                        let destination = routeJSON.destinationAddress
                        let prefixLength = routeJSON.networkPrefixLength ?? 128
                        let route = NEIPv6Route(
                            destinationAddress: destination,
                            networkPrefixLength: NSNumber(value: prefixLength))
                        if let gateway = routeJSON.gatewayAddress {
                            route.gatewayAddress = gateway
                        }
                        includedRoutes.append(route)
                    }
                }
            }
            ipv6Settings.includedRoutes = includedRoutes

            var excludedRoutes: [NEIPv6Route] = []
            if let routesJSON = json.ipv6ExcludedRoutes {
                for routeJSON in routesJSON {
                    if routeJSON.isDefault == true {
                        excludedRoutes.append(NEIPv6Route.default())
                    } else {
                        let destination = routeJSON.destinationAddress
                        let prefixLength = routeJSON.networkPrefixLength ?? 128
                        let route = NEIPv6Route(
                            destinationAddress: destination,
                            networkPrefixLength: NSNumber(value: prefixLength))
                        if let gateway = routeJSON.gatewayAddress {
                            route.gatewayAddress = gateway
                        }
                        excludedRoutes.append(route)
                    }
                }
            }
            ipv6Settings.excludedRoutes = excludedRoutes

            settings.ipv6Settings = ipv6Settings
        } else if let existingIPv6 = existing?.ipv6Settings {
            // Preserve existing IPv6 settings if not being updated
            settings.ipv6Settings = existingIPv6
        }

        // If no IPv4 settings were set from JSON, preserve existing ones
        if settings.ipv4Settings == nil, let existingIPv4 = existing?.ipv4Settings {
            settings.ipv4Settings = existingIPv4
        }

        return settings
    }

    private func updateNetworkSettings(_ settings: NEPacketTunnelNetworkSettings) {
        packetTunnelProvider?.setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                os_log(
                    "Failed to update network settings: %{public}@", log: self.logger, type: .error,
                    error.localizedDescription)
            } else {
                os_log("Network settings updated successfully", log: self.logger, type: .debug)
                self.lastAppliedSettings = settings
            }
        }
    }
}
