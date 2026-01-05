//
//  PreferencesView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

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
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("DNS Settings")) {
                Toggle(isOn: Binding(
                    get: { dnsOverrideEnabled },
                    set: { newValue in
                        _ = configManager.setDNSOverrideEnabled(newValue)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DNS Override")
                            .font(.body)
                        Text("When enabled, the tunnel uses custom DNS servers to resolve internal resources and aliases. External queries use your configured upstream DNS.")
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
                        Text("DNS Tunnel")
                            .font(.body)
                        Text("When enabled, DNS queries are sent through the tunnel to a resource. A private resource must be created for the address for it to work and resolve to the correct site.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .tint(.accentColor)
                
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
