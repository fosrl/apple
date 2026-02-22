import SwiftUI

struct PreferencesView: View {
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
        NavigationStack {
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
                }

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
                    Button(action: {
                        editingPrimaryDNS = primaryDNSServer
                        showPrimaryDNSModal = true
                    }) {
                        HStack {
                            Text("Primary Upstream DNS Server")
                            Spacer()
                            Text(primaryDNSServer)
                                .foregroundColor(.secondary)
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                        editingSecondaryDNS = secondaryDNSServer
                        showSecondaryDNSModal = true
                    }) {
                        HStack {
                            Text("Secondary Upstream DNS Server")
                            Spacer()
                            Text(displaySecondaryDNS)
                                .foregroundColor(.secondary)
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                }
                }
            }
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPrimaryDNSModal) {
                DNSServerModalView(
                    title: "Primary Upstream DNS Server",
                    dnsServer: $editingPrimaryDNS,
                    isPresented: $showPrimaryDNSModal,
                    onSave: { newValue in
                        _ = configManager.setPrimaryDNSServer(newValue)
                    }
                )
            }
            .sheet(isPresented: $showSecondaryDNSModal) {
                DNSServerModalView(
                    title: "Secondary Upstream DNS Server",
                    dnsServer: $editingSecondaryDNS,
                    isPresented: $showSecondaryDNSModal,
                    onSave: { newValue in
                        _ = configManager.setSecondaryDNSServer(newValue)
                    }
                )
            }
        }
    }
}
