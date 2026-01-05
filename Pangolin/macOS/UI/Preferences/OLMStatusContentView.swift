//
//  OLMStatusContentView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI
import AppKit

enum DisplayMode: String, CaseIterable {
    case formatted = "Formatted"
    case json = "JSON"
}

struct OLMStatusContentView: View {
    @ObservedObject var olmStatusManager: OLMStatusManager
    @State private var displayMode: DisplayMode = .formatted
    
    // Computed property to format socket status as JSON
    private var statusJSON: String? {
        guard let socketStatus = olmStatusManager.socketStatus else {
            return nil
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let jsonData = try? encoder.encode(socketStatus),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return jsonString
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Mode selector
            Picker("", selection: $displayMode) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 8)
            
            // Content based on mode
            if displayMode == .json {
                jsonView
            } else {
                formattedView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Start separate polling for live updates when view appears
            olmStatusManager.startPolling()
        }
        .onDisappear {
            // Stop polling when view disappears to avoid unnecessary work
            olmStatusManager.stopPolling()
        }
    }
    
    // MARK: - JSON View
    
    private var jsonView: some View {
        ScrollView {
            if let json = statusJSON {
                VStack(alignment: .leading, spacing: 12) {
                    Text(json)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                Form {
                    Section {
                        HStack {
                            Text("Status")
                                .font(.system(size: 13))
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.gray)
                                    .frame(width: 8, height: 8)
                                Text("Disconnected")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Text("Connection Status")
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
    }
    
    // MARK: - Formatted View
    
    private var formattedView: some View {
        ScrollView {
            if let status = olmStatusManager.socketStatus {
                Form {
                    // Overall Status Section
                    Section {
                        HStack {
                            Text("Agent")
                                .font(.system(size: 13))
                            Spacer()
                            Text(status.agent ?? "Unknown")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        
                        if let version = status.version {
                            HStack {
                                Text("Version")
                                    .font(.system(size: 13))
                                Spacer()
                                Text(version)
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack {
                            Text("Status")
                                .font(.system(size: 13))
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(status.connected ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                Text(formatStatus(connected: status.connected, registered: status.registered))
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let orgId = status.orgId {
                            HStack {
                                Text("Organization")
                                    .font(.system(size: 13))
                                Spacer()
                                Text(orgId)
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Text("Connection Status")
                    }
                    
                    // Peers Section
                    if let peers = status.peers, !peers.isEmpty {
                        Section {
                            ForEach(Array(peers.keys.sorted()), id: \.self) { peerKey in
                                if let peer = peers[peerKey] {
                                    PeerRowView(peer: peer)
                                }
                            }
                        } header: {
                            Text("Sites")
                        }
                    } else {
                        Section {
                            Text("No sites connected")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        } header: {
                            Text("Sites")
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            } else {
                Form {
                    Section {
                        HStack {
                            Text("Status")
                                .font(.system(size: 13))
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.gray)
                                    .frame(width: 8, height: 8)
                                Text("Disconnected")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Text("Connection Status")
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func formatStatus(connected: Bool, registered: Bool?) -> String {
        if connected {
            if registered == true {
                return "Connected"
            } else {
                return "Connected"
            }
        } else {
            return "Disconnected"
        }
    }
}

// MARK: - Peer Row View

struct PeerRowView: View {
    let peer: SocketPeer
    
    var body: some View {
        HStack {
            // Peer name
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name ?? "Unknown")
                    .font(.system(size: 13))
                if let endpoint = peer.endpoint {
                    Text(endpoint)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Status indicators
            HStack(spacing: 12) {
                // Connected status
                HStack(spacing: 4) {
                    Circle()
                        .fill((peer.connected ?? false) ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(formatStatus(peer.connected ?? false))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    private func formatStatus(_ connected: Bool) -> String {
        return connected ? "Connected" : "Disconnected"
    }
}

