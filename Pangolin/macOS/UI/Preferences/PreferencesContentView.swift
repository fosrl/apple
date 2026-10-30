import SwiftUI
import AppKit

struct PreferencesContentView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager()
    @State private var showPrimaryDNSModal = false
    @State private var showSecondaryDNSModal = false
    @State private var showMTUModal = false
    @State private var editingPrimaryDNS = ""
    @State private var editingSecondaryDNS = ""
    @State private var editingMTU = ""
    @State private var showEnableDNSOverrideAlert = false
    @State private var showLaunchAtLoginErrorAlert = false
    @State private var pendingScopedChange: ((SettingsScope) -> Void)?

    /// Applies a change, asking first whether it's global or for this org when that's not known.
    private func applyScoped(_ change: @escaping (SettingsScope) -> Void) {
        configManager.applyScoped(change) { pendingScopedChange = $0 }
    }

    /// Same as `applyScoped` for the DNS and MTU sheets. The question can't be presented until
    /// the sheet has finished closing.
    private func applyScopedAfterSheet(_ change: @escaping (SettingsScope) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
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

                    Section(header: Text("General")) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Start at Login")
                                    .font(.system(size: 13))
                                Text("Automatically open Pangolin when you log in to your Mac.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { launchAtLoginManager.isEnabled },
                                set: { newValue in
                                    launchAtLoginManager.setEnabled(newValue)
                                    if launchAtLoginManager.errorMessage != nil {
                                        showLaunchAtLoginErrorAlert = true
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                    }

                    OnDemandActivationSection(
                        configManager: configManager,
                        tunnelManager: tunnelManager
                    )

                    Section(header: Text("DNS Settings")) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Aliases (DNS Override)")
                                    .font(.system(size: 13))
                                Text("When enabled, the client uses custom DNS servers to resolve internal resources and aliases. This overrides your system's default DNS settings. Queries that cannot be resolved as a Pangolin resource will be forwarded to your configured Upstream DNS Server.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { dnsOverrideEnabled },
                                set: { newValue in
                                    applyScoped { scope in
                                        if !configManager.setDNSOverrideEnabled(newValue, scope: scope) {
                                            showEnableDNSOverrideAlert = true
                                        }
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(serverSettings?.overrideDns != nil)
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("DNS Over Tunnel")
                                    .font(.system(size: 13))
                                Text("When enabled, DNS queries are routed through the tunnel for remote resolution. To ensure queries are tunneled correctly, you must define the DNS server as a Pangolin resource and enter its address as an Upstream DNS Server.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { dnsTunnelEnabled },
                                set: { newValue in
                                    applyScoped { scope in
                                        _ = configManager.setDNSTunnelEnabled(newValue, scope: scope)
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(!dnsOverrideEnabled || serverSettings?.tunnelDns != nil)
                        }
                        
                        if dnsOverrideEnabled {
                            HStack {
                                Text("Primary Upstream DNS Server")
                                    .font(.system(size: 13))
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
                                .disabled(serverSettings?.managesUpstreamDNS == true)
                            }
                        }
                    }

                    Section(header: Text("Advanced")) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Exit Node Takes Precedence Over Resources")
                                    .font(.system(size: 13))
                                Text("When enabled, routes for individual resources are not added to the system and their aliases are not resolved, so all traffic is sent through the exit node instead of directly to resources.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { exitNodeTakesPrecedence },
                                set: { newValue in
                                    applyScoped { scope in
                                        _ = configManager.setExitNodeTakesPrecedence(newValue, scope: scope)
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(serverSettings?.exitNodeTakesPrecedence != nil)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("MTU")
                                    .font(.system(size: 13))
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

                    OrgSettingsResetSection(configManager: configManager)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(SettingsScopePrompt(configManager: configManager, pendingChange: $pendingScopedChange))
        .task {
            await tunnelManager.refreshClientSettings()
        }
        .sheet(isPresented: $showPrimaryDNSModal) {
            DNSServerModalView(
                title: "Primary Upstream DNS Server:",
                dnsServer: $editingPrimaryDNS,
                isPresented: $showPrimaryDNSModal,
                onSave: { newValue in
                    applyScopedAfterSheet { scope in
                        _ = configManager.setPrimaryDNSServer(newValue, scope: scope)
                    }
                }
            )
        }
        .sheet(isPresented: $showSecondaryDNSModal) {
            DNSServerModalView(
                title: "Secondary Upstream DNS Server:",
                dnsServer: $editingSecondaryDNS,
                isPresented: $showSecondaryDNSModal,
                onSave: { newValue in
                    applyScopedAfterSheet { scope in
                        _ = configManager.setSecondaryDNSServer(newValue, scope: scope)
                    }
                }
            )
        }
        .sheet(isPresented: $showMTUModal) {
            MTUModalView(
                title: "MTU:",
                mtuValue: $editingMTU,
                isPresented: $showMTUModal,
                onSave: { newValue in
                    applyScopedAfterSheet { scope in
                        _ = configManager.setTunnelMTUFromString(newValue, scope: scope)
                    }
                }
            )
        }
        .alert("Upstream DNS Server Required", isPresented: $showEnableDNSOverrideAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Set a Primary or Secondary Upstream DNS Server before enabling Aliases (DNS Override).")
        }
        .alert("Start at Login", isPresented: $showLaunchAtLoginErrorAlert) {
            Button("OK", role: .cancel) {
                launchAtLoginManager.errorMessage = nil
            }
        } message: {
            Text(launchAtLoginManager.errorMessage ?? "Unable to update the Start at Login setting.")
        }
        .onAppear {
            launchAtLoginManager.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLoginManager.refresh()
            Task { await tunnelManager.refreshClientSettings() }
        }
    }
}

