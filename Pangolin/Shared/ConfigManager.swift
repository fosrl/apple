import Combine
import Foundation
import SwiftUI
import os.log

class ConfigManager: ObservableObject {
    @Published var config: Config?

    static let defaultHostname = "https://app.pangolin.net"

    private let configPath: URL
    static let defaultTunnelMTU = 1280
    private static let tunnelMTURange = 576...65535

    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return OSLog(subsystem: subsystem, category: "ConfigManager")
    }()

    init() {
        // Migrate data from sandboxed location if needed (macOS only)
        #if os(macOS)
        _ = SandboxMigration.migrateIfNeeded()
        #endif
        
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let pangolinDir = appSupport.appendingPathComponent("Pangolin", isDirectory: true)

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: pangolinDir, withIntermediateDirectories: true)

        self.configPath = pangolinDir.appendingPathComponent("pangolin.json")
        self.config = load()
        ensureDNSDefaults()
    }

    private func ensureDNSDefaults() {
        var updatedConfig = config ?? Config()
        var needsSave = false

        // DNS override defaults to on for both platforms. macOS can fall back to
        // SCDynamicStore-detected system DNS when left blank (see
        // NetworkTransitionMonitor), so primary/secondary stay nil/empty there. iOS has no
        // such fallback, so its primary server is pre-seeded with a real default below instead
        // of being left blank - see setDNSOverrideEnabled for why that matters.
        if updatedConfig.dnsOverrideEnabled == nil {
            updatedConfig.dnsOverrideEnabled = true
            updatedConfig.dnsTunnelEnabled = false
            needsSave = true
        }

        #if os(iOS)
            if updatedConfig.primaryDNSServer == nil {
                updatedConfig.primaryDNSServer = "1.1.1.1"
                needsSave = true
            }
        #endif

        if needsSave {
            // Update config synchronously during init to avoid async issues
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(updatedConfig)
                try data.write(to: configPath)
                self.config = updatedConfig
            } catch {
                os_log(
                    "Error saving DNS defaults: %{public}@", log: logger, type: .error,
                    error.localizedDescription)
            }
        }
    }

    func load() -> Config? {
        guard FileManager.default.fileExists(atPath: configPath.path),
            let data = try? Data(contentsOf: configPath)
        else {
            return Config()
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(Config.self, from: data)
        } catch {
            os_log(
                "Error loading config: %{public}@", log: logger, type: .error,
                error.localizedDescription)
            return Config()
        }
    }

    func save(_ config: Config) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configPath)

            DispatchQueue.main.async {
                self.config = config
            }

            return true
        } catch {
            os_log(
                "Error saving config: %{public}@", log: logger, type: .error,
                error.localizedDescription)
            return false
        }
    }

    // MARK: - DNS Settings

    func getDNSOverrideEnabled() -> Bool {
        return config?.dnsOverrideEnabled ?? true
    }

    /// Whether at least one upstream DNS server is configured. Required on iOS before DNS
    /// override can be turned on (see `setDNSOverrideEnabled`) since it has no automatic
    /// fallback to the real system DNS to lean on instead, unlike macOS.
    var hasUpstreamDNSServer: Bool {
        !getPrimaryDNSServer().isEmpty || !getSecondaryDNSServer().isEmpty
    }

    func getDNSTunnelEnabled() -> Bool {
        return config?.dnsTunnelEnabled ?? false
    }

    func getPrimaryDNSServer() -> String {
        return config?.primaryDNSServer ?? ""
    }

    func getSecondaryDNSServer() -> String {
        // Return empty string if not set (no default for secondary)
        return config?.secondaryDNSServer ?? ""
    }

    /// Enables or disables DNS override. On iOS, requires at least one upstream DNS server to
    /// already be configured before it can be turned on (see `hasUpstreamDNSServer`) - returns
    /// false and leaves the setting unchanged if enabling is requested without one. macOS has no
    /// such requirement: leaving both blank there falls back to SCDynamicStore-detected system
    /// DNS instead.
    func setDNSOverrideEnabled(_ enabled: Bool) -> Bool {
        #if os(iOS)
            if enabled && !hasUpstreamDNSServer {
                return false
            }
        #endif
        var updatedConfig = config ?? Config()
        updatedConfig.dnsOverrideEnabled = enabled
        if !enabled {
            updatedConfig.dnsTunnelEnabled = false
        }
        return save(updatedConfig)
    }

    func setDNSTunnelEnabled(_ enabled: Bool) -> Bool {
        var updatedConfig = config ?? Config()
        updatedConfig.dnsTunnelEnabled = enabled
        return save(updatedConfig)
    }

    /// Sets the primary upstream DNS server. On iOS, returns false and leaves the setting
    /// unchanged if clearing it would leave DNS override enabled with no upstream DNS server
    /// configured at all (see `setDNSOverrideEnabled`).
    func setPrimaryDNSServer(_ server: String) -> Bool {
        let trimmed: String? = server.isEmpty ? nil : server
        #if os(iOS)
            if trimmed == nil, getDNSOverrideEnabled(), getSecondaryDNSServer().isEmpty {
                return false
            }
        #endif
        var updatedConfig = config ?? Config()
        updatedConfig.primaryDNSServer = trimmed
        return save(updatedConfig)
    }

    /// Sets the secondary upstream DNS server. On iOS, returns false and leaves the setting
    /// unchanged if clearing it would leave DNS override enabled with no upstream DNS server
    /// configured at all (see `setDNSOverrideEnabled`).
    func setSecondaryDNSServer(_ server: String) -> Bool {
        let trimmed: String? = server.isEmpty ? nil : server
        #if os(iOS)
            if trimmed == nil, getDNSOverrideEnabled(), getPrimaryDNSServer().isEmpty {
                return false
            }
        #endif
        var updatedConfig = config ?? Config()
        updatedConfig.secondaryDNSServer = trimmed
        return save(updatedConfig)
    }

    /// On iOS, returns false and leaves settings unchanged if overrideEnabled is true but both
    /// primary and secondary are empty (see `setDNSOverrideEnabled`).
    func setDNSSettings(overrideEnabled: Bool, primary: String, secondary: String) -> Bool {
        #if os(iOS)
            if overrideEnabled && primary.isEmpty && secondary.isEmpty {
                return false
            }
        #endif
        var updatedConfig = config ?? Config()
        updatedConfig.dnsOverrideEnabled = overrideEnabled
        updatedConfig.dnsTunnelEnabled = overrideEnabled
        updatedConfig.primaryDNSServer = primary.isEmpty ? nil : primary
        updatedConfig.secondaryDNSServer = secondary.isEmpty ? nil : secondary
        return save(updatedConfig)
    }

    // MARK: - Match Domains

    /// FQDN wildcard patterns (using * and ? wildcards, e.g. "*.proxy.internal") that olm
    /// should check against local records/upstream DNS. Queries for domains that don't match
    /// any pattern are sent directly to the host's system DNS servers instead.
    func getMatchDomains() -> [String] {
        return config?.matchDomains ?? []
    }

    func setMatchDomains(_ domains: [String]) -> Bool {
        var updatedConfig = config ?? Config()
        let trimmed = domains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        updatedConfig.matchDomains = trimmed.isEmpty ? nil : trimmed
        return save(updatedConfig)
    }

    // MARK: - Advanced / MTU

    func getTunnelMTU() -> Int {
        if let mtu = config?.tunnelMTU, Self.tunnelMTURange.contains(mtu) {
            return mtu
        }
        return Self.defaultTunnelMTU
    }

    func setTunnelMTU(_ mtu: Int?) -> Bool {
        var updatedConfig = config ?? Config()
        if let mtu {
            guard Self.tunnelMTURange.contains(mtu) else { return false }
            updatedConfig.tunnelMTU = mtu
        } else {
            updatedConfig.tunnelMTU = nil
        }
        return save(updatedConfig)
    }

    func setTunnelMTUFromString(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return setTunnelMTU(nil)
        }
        guard let mtu = Int(trimmed), Self.tunnelMTURange.contains(mtu) else {
            return false
        }
        return setTunnelMTU(mtu)
    }
}
