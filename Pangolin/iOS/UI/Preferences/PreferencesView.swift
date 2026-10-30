import SwiftUI

struct PreferencesView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager
    @AppStorage(VPNLiveActivityManager.enabledDefaultsKey) private var liveActivityEnabled = true
    @State private var pendingScopedChange: ((SettingsScope) -> Void)?

    /// Applies a change, asking first whether it's global or for this org when that's not known.
    private func applyScoped(_ change: @escaping (SettingsScope) -> Void) {
        configManager.applyScoped(change) { pendingScopedChange = $0 }
    }

    /// Same as `applyScoped` for the DNS and MTU screens. The question can't be presented until
    /// the pushed screen has finished popping back here.
    private func applyScopedAfterPop(_ change: @escaping (SettingsScope) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            applyScoped(change)
        }
    }

    private var serverSettings: ClientSettings? {
        configManager.serverSettings
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
        NavigationStack {
            Form {
                OrgSettingsModeSection(configManager: configManager)

                Section(header: Text("General")) {
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

                Section(header: Text("DNS Settings")) {
                    Toggle(isOn: Binding(
                        get: { dnsOverrideEnabled },
                        set: { newValue in
                            applyScoped { scope in
                                _ = configManager.setDNSOverrideEnabled(newValue, scope: scope)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enable Aliases (DNS Override)")
                                .font(.body)
                            Text("When enabled, the client uses custom DNS servers to resolve internal resources and aliases. This overrides your system's default DNS settings. Queries that cannot be resolved as a Pangolin resource will be forwarded to your configured Upstream DNS Server.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(.accentColor)
                    .disabled(serverSettings?.overrideDns != nil)

                    Toggle(isOn: Binding(
                        get: { dnsTunnelEnabled },
                        set: { newValue in
                            applyScoped { scope in
                                _ = configManager.setDNSTunnelEnabled(newValue, scope: scope)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("DNS Over Tunnel")
                                .font(.body)
                            Text("When enabled, DNS queries are routed through the tunnel for remote resolution. To ensure queries are tunneled correctly, you must define the DNS server as a Pangolin resource and enter its address as an Upstream DNS Server.")
                                .font(.caption)
                                .foregroundColor(.secondary)
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
                                    applyScopedAfterPop { scope in
                                        _ = configManager.setPrimaryDNSServer(newValue, scope: scope)
                                    }
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
                                    applyScopedAfterPop { scope in
                                        _ = configManager.setSecondaryDNSServer(newValue, scope: scope)
                                    }
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
                    }
                }

                Section(header: Text("Advanced")) {
                    Toggle(isOn: Binding(
                        get: { exitNodeTakesPrecedence },
                        set: { newValue in
                            applyScoped { scope in
                                _ = configManager.setExitNodeTakesPrecedence(newValue, scope: scope)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Exit Node Takes Precedence Over Resources")
                                .font(.body)
                            Text("When enabled, routes for individual resources are not added to the system and their aliases are not resolved, so all traffic is sent through the exit node instead of directly to resources.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(.accentColor)
                    .disabled(serverSettings?.exitNodeTakesPrecedence != nil)

                    NavigationLink {
                        MTUModalView(
                            title: "MTU",
                            initialValue: tunnelMTUDisplay,
                            onSave: { newValue in
                                applyScopedAfterPop { scope in
                                    _ = configManager.setTunnelMTUFromString(newValue, scope: scope)
                                }
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

                OrgSettingsResetSection(configManager: configManager)
            }
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(SettingsScopePrompt(configManager: configManager, pendingChange: $pendingScopedChange))
            .task {
                await tunnelManager.refreshClientSettings()
            }
        }
    }
}
