import SwiftUI

struct PreferencesContentView: View {
    @ObservedObject var configManager: ConfigManager
    @State private var showPrimaryDNSModal = false
    @State private var showSecondaryDNSModal = false
    @State private var editingPrimaryDNS = ""
    @State private var editingSecondaryDNS = ""
    
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

    private static let docsConfigureClientURL = URL(string: "https://docs.pangolin.net/manage/clients/configure-client")!
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Form {
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
                        .foregroundColor(.accentColor)
                    }

                    Section(header: Text("DNS Settings")) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Aliases (DNS Override)")
                                    .font(.system(size: 13))
                                Text("When enabled, the client uses custom DNS servers to resolve internal resources and aliases. This overrides your system's default DNS settings. Queries that cannot be resolved as a CNDF-VPN resource will be forwarded to your configured Upstream DNS Server.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { dnsOverrideEnabled },
                                set: { newValue in
                                    _ = configManager.setDNSOverrideEnabled(newValue)
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("DNS Over Tunnel")
                                    .font(.system(size: 13))
                                Text("When enabled, DNS queries are routed through the tunnel for remote resolution. To ensure queries are tunneled correctly, you must define the DNS server as a CNDF-VPN resource and enter its address as an Upstream DNS Server.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { dnsTunnelEnabled },
                                set: { newValue in
                                    _ = configManager.setDNSTunnelEnabled(newValue)
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(!dnsOverrideEnabled)
                        }
                        
                        if dnsOverrideEnabled {
                            HStack {
                                Text("Primary Upstream DNS Server")
                                    .font(.system(size: 13))
                                Spacer()
                                Text(primaryDNSServer)
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                Button("Set...") {
                                    editingPrimaryDNS = primaryDNSServer
                                    showPrimaryDNSModal = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            
                            HStack {
                                Text("Secondary Upstream DNS Server")
                                    .font(.system(size: 13))
                                Spacer()
                                Text(displaySecondaryDNS)
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                Button("Set...") {
                                    editingSecondaryDNS = secondaryDNSServer
                                    showSecondaryDNSModal = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showPrimaryDNSModal) {
            DNSServerModalView(
                title: "Primary Upstream DNS Server:",
                dnsServer: $editingPrimaryDNS,
                isPresented: $showPrimaryDNSModal,
                onSave: { newValue in
                    _ = configManager.setPrimaryDNSServer(newValue)
                }
            )
        }
        .sheet(isPresented: $showSecondaryDNSModal) {
            DNSServerModalView(
                title: "Secondary Upstream DNS Server:",
                dnsServer: $editingSecondaryDNS,
                isPresented: $showSecondaryDNSModal,
                onSave: { newValue in
                    _ = configManager.setSecondaryDNSServer(newValue)
                }
            )
        }
    }
}

