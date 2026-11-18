import Combine
import Foundation
import SwiftUI
import os.log

class ConfigManager: ObservableObject {
    @Published var config: Config?

    /// The org the org-specific getters below resolve for, and what its server manages. Set by
    /// `TunnelManager.refreshClientSettings`.
    @Published private(set) var activeOrgId: String?
    @Published private(set) var activeOrgName: String?
    @Published private(set) var serverSettings: ClientSettings?

    static let defaultHostname = "https://app.pangolin.net"

    private let configPath: URL
    static let defaultTunnelMTU = 1280
    private static let tunnelMTURange = 576...65535

    private let logger: PangolinLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return PangolinLog(subsystem: subsystem, category: "ConfigManager")
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

            // Prefer an immediate update when already on the main thread so
            // subsequent reads in the same call stack see fresh values.
            if Thread.isMainThread {
                self.config = config
            } else {
                DispatchQueue.main.async {
                    self.config = config
                }
            }

            return true
        } catch {
            os_log(
                "Error saving config: %{public}@", log: logger, type: .error,
                error.localizedDescription)
            return false
        }
    }

    // MARK: - Org Settings

    func setActiveOrg(id: String?, name: String?, serverSettings: ClientSettings?) {
        activeOrgId = id
        activeOrgName = name
        self.serverSettings = serverSettings
    }

    func orgConfig(orgId: String) -> OrgConfig? {
        config?.orgs?[orgId]
    }

    private var activeOrgConfig: OrgConfig? {
        activeOrgId.flatMap { orgConfig(orgId: $0) }
    }

    /// Whether the active org has its own settings rather than using the ones for all
    /// organizations. Its chosen exit node and match domains don't count: they aren't part of
    /// the settings the user switches between.
    var isOrgMode: Bool {
        activeOrgConfig?.hasOwnSettings ?? false
    }

    /// Where changes in Settings are saved: the active org's own settings once it has them,
    /// otherwise the ones for all organizations.
    var activeScope: SettingsScope {
        activeOrgId != nil && isOrgMode ? .org : .global
    }

    /// Gives the active org its own settings, starting as a copy of the ones it uses now, so
    /// nothing changes until the user edits them. Every setting is copied, so later changes to
    /// the settings for all organizations don't affect it. Values the org's administrator sets
    /// aren't copied: they still apply on top.
    func giveActiveOrgOwnSettings() -> Bool {
        guard activeOrgId != nil else { return false }
        let global = config
        let globalMTU = global?.tunnelMTU.flatMap { Self.tunnelMTURange.contains($0) ? $0 : nil }
        return update(scope: .org, global: { _ in }) { org in
            org.dnsOverrideEnabled = org.dnsOverrideEnabled ?? global?.dnsOverrideEnabled ?? true
            org.dnsTunnelEnabled = org.dnsTunnelEnabled ?? global?.dnsTunnelEnabled ?? false
            org.primaryDNSServer = org.primaryDNSServer ?? global?.primaryDNSServer ?? ""
            org.secondaryDNSServer = org.secondaryDNSServer ?? global?.secondaryDNSServer ?? ""
            org.exitNodeTakesPrecedence =
                org.exitNodeTakesPrecedence ?? global?.exitNodeTakesPrecedence ?? false
            org.tunnelMTU = org.tunnelMTU ?? globalMTU ?? Self.defaultTunnelMTU
        }
    }

    /// Removes the active org's own settings so it uses the ones for all organizations again.
    /// Its chosen exit node and match domains aren't part of them, so they're kept.
    func resetActiveOrgSettings() -> Bool {
        guard activeOrgId != nil else { return true }
        return update(scope: .org, global: { _ in }) { org in
            org.dnsOverrideEnabled = nil
            org.dnsTunnelEnabled = nil
            org.primaryDNSServer = nil
            org.secondaryDNSServer = nil
            org.exitNodeTakesPrecedence = nil
            org.tunnelMTU = nil
        }
    }

    /// Saves a change to the global settings or the active org's own.
    private func update(
        scope: SettingsScope,
        global: (inout Config) -> Void,
        org: (inout OrgConfig) -> Void
    ) -> Bool {
        var updatedConfig = config ?? Config()
        if scope == .org, let activeOrgId {
            var orgs = updatedConfig.orgs ?? [:]
            var entry = orgs[activeOrgId] ?? OrgConfig()
            org(&entry)
            orgs[activeOrgId] = entry.isEmpty ? nil : entry
            updatedConfig.orgs = orgs.isEmpty ? nil : orgs
        } else {
            global(&updatedConfig)
        }
        return save(updatedConfig)
    }

    // MARK: - DNS Settings

    func getDNSOverrideEnabled() -> Bool {
        return serverSettings?.overrideDns ?? activeOrgConfig?.dnsOverrideEnabled
            ?? config?.dnsOverrideEnabled ?? true
    }

    /// Whether at least one upstream DNS server is configured. Required on iOS before DNS
    /// override can be turned on (see `setDNSOverrideEnabled`) since it has no automatic
    /// fallback to the real system DNS to lean on instead, unlike macOS.
    var hasUpstreamDNSServer: Bool {
        !getPrimaryDNSServer().isEmpty || !getSecondaryDNSServer().isEmpty
    }

    func getDNSTunnelEnabled() -> Bool {
        return serverSettings?.tunnelDns ?? activeOrgConfig?.dnsTunnelEnabled
            ?? config?.dnsTunnelEnabled ?? false
    }

    func getPrimaryDNSServer() -> String {
        if let serverSettings, serverSettings.managesUpstreamDNS {
            return serverSettings.primaryDns ?? ""
        }
        return activeOrgConfig?.primaryDNSServer ?? config?.primaryDNSServer ?? ""
    }

    func getSecondaryDNSServer() -> String {
        if let serverSettings, serverSettings.managesUpstreamDNS {
            return serverSettings.secondaryDns ?? ""
        }
        // Return empty string if not set (no default for secondary)
        return activeOrgConfig?.secondaryDNSServer ?? config?.secondaryDNSServer ?? ""
    }

    /// Enables or disables DNS override. On iOS, requires at least one upstream DNS server to
    /// already be configured before it can be turned on (see `hasUpstreamDNSServer`) - returns
    /// false and leaves the setting unchanged if enabling is requested without one. macOS has no
    /// such requirement: leaving both blank there falls back to SCDynamicStore-detected system
    /// DNS instead.
    func setDNSOverrideEnabled(_ enabled: Bool, scope: SettingsScope = .global) -> Bool {
        #if os(iOS)
            if enabled && !hasUpstreamDNSServer {
                return false
            }
        #endif
        return update(
            scope: scope,
            global: {
                $0.dnsOverrideEnabled = enabled
                if !enabled { $0.dnsTunnelEnabled = false }
            },
            org: {
                $0.dnsOverrideEnabled = enabled
                if !enabled { $0.dnsTunnelEnabled = false }
            })
    }

    func setDNSTunnelEnabled(_ enabled: Bool, scope: SettingsScope = .global) -> Bool {
        update(
            scope: scope,
            global: { $0.dnsTunnelEnabled = enabled },
            org: { $0.dnsTunnelEnabled = enabled })
    }

    /// Sets the primary upstream DNS server. On iOS, returns false and leaves the setting
    /// unchanged if clearing it would leave DNS override enabled with no upstream DNS server
    /// configured at all (see `setDNSOverrideEnabled`).
    func setPrimaryDNSServer(_ server: String, scope: SettingsScope = .global) -> Bool {
        let trimmed: String? = server.isEmpty ? nil : server
        #if os(iOS)
            if trimmed == nil, getDNSOverrideEnabled(), getSecondaryDNSServer().isEmpty {
                return false
            }
        #endif
        // An org keeps an empty string so it can clear a server the global settings define.
        return update(
            scope: scope,
            global: { $0.primaryDNSServer = trimmed },
            org: { $0.primaryDNSServer = server })
    }

    /// Sets the secondary upstream DNS server. On iOS, returns false and leaves the setting
    /// unchanged if clearing it would leave DNS override enabled with no upstream DNS server
    /// configured at all (see `setDNSOverrideEnabled`).
    func setSecondaryDNSServer(_ server: String, scope: SettingsScope = .global) -> Bool {
        let trimmed: String? = server.isEmpty ? nil : server
        #if os(iOS)
            if trimmed == nil, getDNSOverrideEnabled(), getPrimaryDNSServer().isEmpty {
                return false
            }
        #endif
        // An org keeps an empty string so it can clear a server the global settings define.
        return update(
            scope: scope,
            global: { $0.secondaryDNSServer = trimmed },
            org: { $0.secondaryDNSServer = server })
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
        return serverSettings?.matchDomains ?? activeOrgConfig?.matchDomains
            ?? config?.matchDomains ?? []
    }

    func setMatchDomains(_ domains: [String]) -> Bool {
        var updatedConfig = config ?? Config()
        let trimmed = domains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        updatedConfig.matchDomains = trimmed.isEmpty ? nil : trimmed
        return save(updatedConfig)
    }

    // MARK: - Session Cookie Name

    /// Override for the cookie name the session token is sent and read under, or empty string
    /// if not set (the API client's built-in default is used).
    func getSessionCookieName() -> String {
        return config?.sessionCookieName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Exit Node Precedence

    /// When enabled, routes for individual resources are not added to the routing table and
    /// their aliases are not resolved, so all traffic is sent through the exit node instead of
    /// directly to resources.
    func getExitNodeTakesPrecedence() -> Bool {
        return serverSettings?.exitNodeTakesPrecedence ?? activeOrgConfig?.exitNodeTakesPrecedence
            ?? config?.exitNodeTakesPrecedence ?? false
    }

    func setExitNodeTakesPrecedence(_ enabled: Bool, scope: SettingsScope = .global) -> Bool {
        update(
            scope: scope,
            global: { $0.exitNodeTakesPrecedence = enabled },
            org: { $0.exitNodeTakesPrecedence = enabled })
    }

    // MARK: - Update Settings

    /// Optional override for Sparkle automatic update checks. `nil` leaves Sparkle prefs alone.
    func getAutoUpdateChecksEnabled() -> Bool? {
        return config?.autoUpdateChecksEnabled
    }

    /// Optional override for Sparkle automatic download/install. `nil` leaves Sparkle prefs alone.
    func getAutoDownloadUpdatesEnabled() -> Bool? {
        return config?.autoDownloadUpdatesEnabled
    }

    /// Optional override for Sparkle check interval in seconds. `nil` leaves Sparkle prefs alone.
    func getUpdateCheckIntervalSeconds() -> Int? {
        return config?.updateCheckIntervalSeconds
    }

    // MARK: - On-Demand Activation

    func getOnDemandNonWiFiEnabled() -> Bool {
        config?.onDemandNonWiFiEnabled ?? false
    }

    func getOnDemandWiFiEnabled() -> Bool {
        config?.onDemandWiFiEnabled ?? false
    }

    func getOnDemandSSIDOption() -> OnDemandSSIDOptionKind {
        config?.onDemandSSIDOption ?? .any
    }

    func getOnDemandSSIDs() -> [String] {
        config?.onDemandSSIDs ?? []
    }

    func onDemandOptionFromConfig() -> ActivateOnDemandOption {
        ActivateOnDemandViewModel(from: config).toOnDemandOption()
    }

    /// Persists on-demand UI state from the view model and returns the resulting option.
    @discardableResult
    func setOnDemandSettings(from viewModel: ActivateOnDemandViewModel) -> ActivateOnDemandOption {
        var updatedConfig = config ?? Config()
        viewModel.apply(to: &updatedConfig)
        _ = save(updatedConfig)
        return viewModel.toOnDemandOption()
    }

    // MARK: - Advanced / MTU

    func getTunnelMTU() -> Int {
        let mtu = serverSettings?.mtu ?? activeOrgConfig?.tunnelMTU ?? config?.tunnelMTU
        if let mtu, Self.tunnelMTURange.contains(mtu) {
            return mtu
        }
        return Self.defaultTunnelMTU
    }

    func setTunnelMTU(_ mtu: Int?, scope: SettingsScope = .global) -> Bool {
        if let mtu {
            guard Self.tunnelMTURange.contains(mtu) else { return false }
        }
        return update(
            scope: scope,
            global: { $0.tunnelMTU = mtu },
            org: { $0.tunnelMTU = mtu })
    }

    func setTunnelMTUFromString(_ string: String, scope: SettingsScope = .global) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return setTunnelMTU(nil, scope: scope)
        }
        guard let mtu = Int(trimmed), Self.tunnelMTURange.contains(mtu) else {
            return false
        }
        return setTunnelMTU(mtu, scope: scope)
    }
}
