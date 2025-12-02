//
//  PreferencesContentView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

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
        VStack(spacing: 0) {
            ScrollView {
                Form {
                    Section(header: Text("DNS Settings")) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("DNS Override")
                                    .font(.system(size: 13))
                                Text("When enabled, the tunnel uses custom DNS servers to resolve internal resources and aliases. External queries use your configured upstream DNS.")
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

