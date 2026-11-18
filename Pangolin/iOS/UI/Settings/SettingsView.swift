import SwiftUI

/// Settings for how the tunnel connects. They can be saved for all organizations or only the
/// current one, unlike the app-wide ones in `GeneralSettingsView`.
struct ConnectionSettingsView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager
    /// Where changes are saved: the current org's own settings if it has them, otherwise the
    /// ones for all organizations.
    private var scope: SettingsScope {
        configManager.activeScope
    }

    private var serverSettings: ClientSettings? {
        configManager.serverSettings
    }

    private var orgName: String {
        configManager.managingOrgName
    }

    private var dnsOverrideEnabled: Bool {
        configManager.getDNSOverrideEnabled()
    }

    private var dnsTunnelEnabled: Bool {
        configManager.getDNSTunnelEnabled()
    }

    private var exitNodeTakesPrecedence: Bool {
        configManager.getExitNodeTakesPrecedence()
    }

    private var primaryDNSServer: String {
        configManager.getPrimaryDNSServer()
    }

    private var secondaryDNSServer: String {
        configManager.getSecondaryDNSServer()
    }

    private var displaySecondaryDNS: String {
        secondaryDNSServer.isEmpty ? "Not set" : secondaryDNSServer
    }

    private var tunnelMTUDisplay: String {
        String(configManager.getTunnelMTU())
    }

    private static let docsConfigureClientURL = URL(string: "https://docs.pangolin.net/manage/clients/configure-client")!

    var body: some View {
        Form {
            OrgSettingsModeSection(configManager: configManager)

            Section(header: Text("DNS Settings")) {
                Toggle(isOn: Binding(
                    get: { dnsOverrideEnabled },
                    set: { newValue in
                        _ = configManager.setDNSOverrideEnabled(newValue, scope: scope)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Aliases (DNS Override)")
                            .font(.body)
                        Text("When enabled, the client uses custom DNS servers to resolve internal resources and aliases. This overrides your system's default DNS settings. Queries that cannot be resolved as a Pangolin resource will be forwarded to your configured Upstream DNS Server.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if serverSettings?.overrideDns != nil {
                            ManagedSettingCaption()
                        }
                    }
                }
                .tint(.accentColor)
                .disabled(serverSettings?.overrideDns != nil)

                Toggle(isOn: Binding(
                    get: { dnsTunnelEnabled },
                    set: { newValue in
                        _ = configManager.setDNSTunnelEnabled(newValue, scope: scope)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DNS Over Tunnel")
                            .font(.body)
                        Text("When enabled, DNS queries are routed through the tunnel for remote resolution. To ensure queries are tunneled correctly, you must define the DNS server as a Pangolin resource and enter its address as an Upstream DNS Server.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if serverSettings?.tunnelDns != nil {
                            ManagedSettingCaption()
                        }
                    }
                }
                .tint(.accentColor)
                .disabled(!dnsOverrideEnabled || serverSettings?.tunnelDns != nil)

                if dnsOverrideEnabled {
                    NavigationLink {
                        DNSServerModalView(
                            title: "Primary Upstream DNS Server",
                            initialValue: primaryDNSServer,
                            onSave: { newValue in
                                _ = configManager.setPrimaryDNSServer(newValue, scope: scope)
                            }
                        )
                    } label: {
                        HStack {
                            Text("Primary Upstream DNS Server")
                            Spacer()
                            Text(primaryDNSServer)
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(serverSettings?.managesUpstreamDNS == true)

                    NavigationLink {
                        DNSServerModalView(
                            title: "Secondary Upstream DNS Server",
                            initialValue: secondaryDNSServer,
                            onSave: { newValue in
                                _ = configManager.setSecondaryDNSServer(newValue, scope: scope)
                            }
                        )
                    } label: {
                        HStack {
                            Text("Secondary Upstream DNS Server")
                            Spacer()
                            Text(displaySecondaryDNS)
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(serverSettings?.managesUpstreamDNS == true)

                    // One caption for both servers, since they're managed together.
                    if serverSettings?.managesUpstreamDNS == true {
                        ManagedSettingCaption()
                    }
                }
            }

            Section(header: Text("Advanced")) {
                Toggle(isOn: Binding(
                    get: { exitNodeTakesPrecedence },
                    set: { newValue in
                        _ = configManager.setExitNodeTakesPrecedence(newValue, scope: scope)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Exit Node Takes Precedence Over Resources")
                            .font(.body)
                        Text("When enabled, routes for individual resources are not added to the system and their aliases are not resolved, so all traffic is sent through the exit node instead of directly to resources.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if serverSettings?.exitNodeTakesPrecedence != nil {
                            ManagedSettingCaption()
                        }
                    }
                }
                .tint(.accentColor)
                .disabled(serverSettings?.exitNodeTakesPrecedence != nil)

                NavigationLink {
                    MTUModalView(
                        title: "MTU",
                        initialValue: tunnelMTUDisplay,
                        onSave: { newValue in
                            _ = configManager.setTunnelMTUFromString(newValue, scope: scope)
                        }
                    )
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MTU")
                                .font(.body)
                            Text("Your sites must be configured to use the same MTU value.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if serverSettings?.mtu != nil {
                                ManagedSettingCaption()
                            }
                        }
                        Spacer()
                        Text(tunnelMTUDisplay)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(serverSettings?.mtu != nil)
            }

            Section(header: Text("Help")) {
                Link(destination: Self.docsConfigureClientURL) {
                    HStack {
                        Text("See docs for more info on these settings")
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await tunnelManager.refreshClientSettings()
        }
    }
}

/// The Settings tab: app-wide settings and connection settings, each on its own page.
struct SettingsView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager
    var splitLeadingInset: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        GeneralSettingsView(configManager: configManager, tunnelManager: tunnelManager)
                    } label: {
                        SettingsLinkLabel(
                            title: "General",
                            subtitle: "Live Activity and on-demand activation. Applies to every organization and account.",
                            systemImage: "gearshape.fill"
                        )
                    }

                    NavigationLink {
                        ConnectionSettingsView(configManager: configManager, tunnelManager: tunnelManager)
                    } label: {
                        SettingsLinkLabel(
                            title: "Connection",
                            subtitle: "DNS and advanced settings. Can be saved for all organizations or only one.",
                            systemImage: "network"
                        )
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        // Outside the stack so pushed settings pages get the inset too.
        .splitPaneLeadingInset(splitLeadingInset)
    }
}

private struct SettingsLinkLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

/// App-wide settings for this device. Unlike `ConnectionSettingsView`, these are the same for
/// every organization and account.
struct GeneralSettingsView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager
    @AppStorage(VPNLiveActivityManager.enabledDefaultsKey) private var liveActivityEnabled = true

    var body: some View {
        Form {
            Section {
                SettingsBannerText(
                    title: "Shared by all organizations and accounts",
                    detail: "These settings apply to every organization and account on this device.",
                    systemImage: "iphone"
                )
            }

            Section {
                Toggle(isOn: $liveActivityEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dynamic Island & Live Activity")
                            .font(.body)
                        Text("Show connection status in the Dynamic Island and on the Lock Screen.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .tint(.accentColor)
                .onChange(of: liveActivityEnabled) { _, _ in
                    VPNLiveActivityManager.shared.applyEnabledPreference()
                }
            }

            OnDemandActivationSection(
                configManager: configManager,
                tunnelManager: tunnelManager
            )
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
    }
}
