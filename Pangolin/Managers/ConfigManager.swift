//
//  ConfigManager.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

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
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return OSLog(subsystem: subsystem, category: "ConfigManager")
    }()

    init() {
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
