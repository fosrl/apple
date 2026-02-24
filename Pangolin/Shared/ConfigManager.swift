import Combine
import Foundation
import SwiftUI
import os.log

class ConfigManager: ObservableObject {
    @Published var config: Config?

    static let defaultHostname = "https://app.pangolin.net"

    private let configPath: URL
    private let defaultPrimaryDNS = "1.1.1.1"

    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "com.cndf.vpn"
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
        let cndfDir = appSupport.appendingPathComponent("CNDFVPN", isDirectory: true)

        // Migrate from old "Pangolin" directory if it exists
        let oldDir = appSupport.appendingPathComponent("Pangolin", isDirectory: true)
        if FileManager.default.fileExists(atPath: oldDir.path) && !FileManager.default.fileExists(atPath: cndfDir.path) {
            try? FileManager.default.moveItem(at: oldDir, to: cndfDir)
        }

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: cndfDir, withIntermediateDirectories: true)

        // Migrate old config file name if needed
        let oldConfig = cndfDir.appendingPathComponent("pangolin.json")
        let newConfig = cndfDir.appendingPathComponent("cndfvpn.json")
        if FileManager.default.fileExists(atPath: oldConfig.path) && !FileManager.default.fileExists(atPath: newConfig.path) {
            try? FileManager.default.moveItem(at: oldConfig, to: newConfig)
        }

        self.configPath = newConfig
        self.config = load()
        ensureDNSDefaults()
    }

    private func ensureDNSDefaults() {
        var updatedConfig = config ?? Config()
        var needsSave = false

        // Ensure primary DNS has default value if not set
        if updatedConfig.primaryDNSServer == nil || updatedConfig.primaryDNSServer?.isEmpty == true
        {
            updatedConfig.primaryDNSServer = defaultPrimaryDNS
            needsSave = true
        }

        // Ensure DNS override has default value if not set
        if updatedConfig.dnsOverrideEnabled == nil {
            updatedConfig.dnsOverrideEnabled = true
            updatedConfig.dnsTunnelEnabled = false
            needsSave = true
        }

        // Secondary DNS can remain nil/empty, no default needed

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

    func getDNSTunnelEnabled() -> Bool {
        return config?.dnsTunnelEnabled ?? false
    }

    func getPrimaryDNSServer() -> String {
        // Config should always have a value after ensureDNSDefaults, but return default as fallback
        return config?.primaryDNSServer ?? defaultPrimaryDNS
    }

    func getDefaultPrimaryDNS() -> String {
        return defaultPrimaryDNS
    }

    func getSecondaryDNSServer() -> String {
        // Return empty string if not set (no default for secondary)
        return config?.secondaryDNSServer ?? ""
    }

    func setDNSOverrideEnabled(_ enabled: Bool) -> Bool {
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

    func setPrimaryDNSServer(_ server: String) -> Bool {
        var updatedConfig = config ?? Config()
        updatedConfig.primaryDNSServer = server.isEmpty ? nil : server
        return save(updatedConfig)
    }

    func setSecondaryDNSServer(_ server: String) -> Bool {
        var updatedConfig = config ?? Config()
        updatedConfig.secondaryDNSServer = server.isEmpty ? nil : server
        return save(updatedConfig)
    }

    func setDNSSettings(overrideEnabled: Bool, primary: String, secondary: String) -> Bool {
        var updatedConfig = config ?? Config()
        updatedConfig.dnsOverrideEnabled = overrideEnabled
        updatedConfig.dnsTunnelEnabled = overrideEnabled
        updatedConfig.primaryDNSServer = primary.isEmpty ? nil : primary
        updatedConfig.secondaryDNSServer = secondary.isEmpty ? nil : secondary
        return save(updatedConfig)
    }
}
