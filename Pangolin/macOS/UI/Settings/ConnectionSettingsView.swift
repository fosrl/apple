import SwiftUI
import AppKit

/// Settings for how the tunnel connects. They can be saved for all organizations or only the
/// current one, unlike the app-wide ones in `GeneralSettingsView`.
struct ConnectionSettingsView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager
    @State private var showPrimaryDNSModal = false
    @State private var showSecondaryDNSModal = false
    @State private var showMTUModal = false
    @State private var editingPrimaryDNS = ""
    @State private var editingSecondaryDNS = ""
    @State private var editingMTU = ""
    @State private var showEnableDNSOverrideAlert = false

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
    
    private var displayPrimaryDNS: String {
        primaryDNSServer.isEmpty ? "System DNS" : primaryDNSServer
    }

    private var displaySecondaryDNS: String {
        secondaryDNSServer.isEmpty ? "System DNS" : secondaryDNSServer
    }

    private var tunnelMTUDisplay: String {
        String(configManager.getTunnelMTU())
    }

    private static let docsConfigureClientURL = URL(string: "https://docs.pangolin.net/manage/clients/configure-client")!
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Form {
                    OrgSettingsModeSection(configManager: configManager)

                    Section(header: Text("DNS Settings")) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Aliases (DNS Override)")
                                    .font(.system(size: 13))
                                    .managedLock(serverSettings?.overrideDns != nil)
                                Text("When enabled, the client uses custom DNS servers to resolve internal resources and aliases. This overrides your system's default DNS settings. Queries that cannot be resolved as a Pangolin resource will be forwarded to your configured Upstream DNS Server.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { dnsOverrideEnabled },
                                set: { newValue in
                                    if !configManager.setDNSOverrideEnabled(newValue, scope: scope) {
                                        showEnableDNSOverrideAlert = true
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(serverSettings?.overrideDns != nil)
                        }
                        .managedSettingHelp(serverSettings?.overrideDns != nil, orgName: orgName)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("DNS Over Tunnel")
                                    .font(.system(size: 13))
                                    .managedLock(serverSettings?.tunnelDns != nil)
                                Text("When enabled, DNS queries are routed through the tunnel for remote resolution. To ensure queries are tunneled correctly, you must define the DNS server as a Pangolin resource and enter its address as an Upstream DNS Server.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { dnsTunnelEnabled },
                                set: { newValue in
                                    _ = configManager.setDNSTunnelEnabled(newValue, scope: scope)
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(!dnsOverrideEnabled || serverSettings?.tunnelDns != nil)
                        }
                        .managedSettingHelp(serverSettings?.tunnelDns != nil, orgName: orgName)
                        
                        if dnsOverrideEnabled {
                            HStack {
                                Text("Primary Upstream DNS Server")
                                    .font(.system(size: 13))
                                    .managedLock(serverSettings?.managesUpstreamDNS == true)
                                Spacer()
                                Text(displayPrimaryDNS)
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                Button("Set...") {
                                    editingPrimaryDNS = primaryDNSServer
                                    showPrimaryDNSModal = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(serverSettings?.managesUpstreamDNS == true)
                            }
                            .managedSettingHelp(serverSettings?.managesUpstreamDNS == true, orgName: orgName)
                            
                            HStack {
                                Text("Secondary Upstream DNS Server")
                                    .font(.system(size: 13))
                                    .managedLock(serverSettings?.managesUpstreamDNS == true)
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
                                .disabled(serverSettings?.managesUpstreamDNS == true)
                            }
                            .managedSettingHelp(serverSettings?.managesUpstreamDNS == true, orgName: orgName)
                        }
                    }

                    BlockPageTrustSection(manager: tunnelManager.blockPageTrust)

                    Section(header: Text("Advanced")) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Exit Node Takes Precedence Over Resources")
                                    .font(.system(size: 13))
                                    .managedLock(serverSettings?.exitNodeTakesPrecedence != nil)
                                Text("When enabled, routes for individual resources are not added to the system and their aliases are not resolved, so all traffic is sent through the exit node instead of directly to resources.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { exitNodeTakesPrecedence },
                                set: { newValue in
                                    _ = configManager.setExitNodeTakesPrecedence(newValue, scope: scope)
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(serverSettings?.exitNodeTakesPrecedence != nil)
                        }
                        .managedSettingHelp(serverSettings?.exitNodeTakesPrecedence != nil, orgName: orgName)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("MTU")
                                    .font(.system(size: 13))
                                    .managedLock(serverSettings?.mtu != nil)
                                Spacer()
                                Text(tunnelMTUDisplay)
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                Button("Set...") {
                                    editingMTU = tunnelMTUDisplay
                                    showMTUModal = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(serverSettings?.mtu != nil)
                            }

                            Text("Your sites must be configured to use the same MTU value.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .managedSettingHelp(serverSettings?.mtu != nil, orgName: orgName)
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
                        .foregroundColor(.accentColor)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await tunnelManager.refreshClientSettings()
        }
        .sheet(isPresented: $showPrimaryDNSModal) {
            DNSServerModalView(
                title: "Primary Upstream DNS Server:",
                dnsServer: $editingPrimaryDNS,
                isPresented: $showPrimaryDNSModal,
                onSave: { newValue in
                    _ = configManager.setPrimaryDNSServer(newValue, scope: scope)
                }
            )
        }
        .sheet(isPresented: $showSecondaryDNSModal) {
            DNSServerModalView(
                title: "Secondary Upstream DNS Server:",
                dnsServer: $editingSecondaryDNS,
                isPresented: $showSecondaryDNSModal,
                onSave: { newValue in
                    _ = configManager.setSecondaryDNSServer(newValue, scope: scope)
                }
            )
        }
        .sheet(isPresented: $showMTUModal) {
            MTUModalView(
                title: "MTU:",
                mtuValue: $editingMTU,
                isPresented: $showMTUModal,
                onSave: { newValue in
                    _ = configManager.setTunnelMTUFromString(newValue, scope: scope)
                }
            )
        }
        .alert("Upstream DNS Server Required", isPresented: $showEnableDNSOverrideAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Set a Primary or Secondary Upstream DNS Server before enabling Aliases (DNS Override).")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await tunnelManager.refreshClientSettings() }
        }
    }
}

