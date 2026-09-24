import SwiftUI

struct PreferencesView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager
    @AppStorage(VPNLiveActivityManager.enabledDefaultsKey) private var liveActivityEnabled = true

    private var dnsOverrideEnabled: Bool {
        configManager.getDNSOverrideEnabled()
    }

    private var dnsTunnelEnabled: Bool {
        configManager.getDNSTunnelEnabled()
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
                            _ = configManager.setDNSOverrideEnabled(newValue)
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

                    Toggle(isOn: Binding(
                        get: { dnsTunnelEnabled },
                        set: { newValue in
                            _ = configManager.setDNSTunnelEnabled(newValue)
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
                    .disabled(!dnsOverrideEnabled)

                    if dnsOverrideEnabled {
                        NavigationLink {
                            DNSServerModalView(
                                title: "Primary Upstream DNS Server",
                                initialValue: primaryDNSServer,
                                onSave: { newValue in
                                    _ = configManager.setPrimaryDNSServer(newValue)
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

                        NavigationLink {
                            DNSServerModalView(
                                title: "Secondary Upstream DNS Server",
                                initialValue: secondaryDNSServer,
                                onSave: { newValue in
                                    _ = configManager.setSecondaryDNSServer(newValue)
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
                    }
                }

                Section(header: Text("Advanced")) {
                    NavigationLink {
                        MTUModalView(
                            title: "MTU",
                            initialValue: tunnelMTUDisplay,
                            onSave: { newValue in
                                _ = configManager.setTunnelMTUFromString(newValue)
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
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
