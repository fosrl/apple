//
//  StatusView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

#if os(iOS)
import SwiftUI
import UIKit

enum DisplayMode: String, CaseIterable {
    case formatted = "Formatted"
    case json = "JSON"
}

struct StatusView: View {
    @ObservedObject var olmStatusManager: OLMStatusManager
    @State private var displayMode: DisplayMode = .formatted
    @State private var showCopyConfirmation = false
    
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
        NavigationStack {
            VStack(spacing: 0) {
                // Mode selector
                Picker("", selection: $displayMode) {
                    ForEach(DisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                .background(Color(.systemGroupedBackground))
                
                // Content based on mode
                if displayMode == .json {
                    jsonView
                } else {
                    formattedView
                }
            }
            .navigationTitle("Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if displayMode == .json && statusJSON != nil {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            if let json = statusJSON {
                                UIPasteboard.general.string = json
                                showCopyConfirmation = true
                                // Hide confirmation after 2 seconds
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    showCopyConfirmation = false
                                }
                            }
                        }) {
                            if showCopyConfirmation {
                                Label("Copied", systemImage: "checkmark")
                            } else {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
            }
            .onAppear {
                // Start separate polling for live updates when view appears
                olmStatusManager.startPolling()
            }
            .onDisappear {
                // Stop polling when view disappears to avoid unnecessary work
                olmStatusManager.stopPolling()
            }
        }
    }
    
    // MARK: - JSON View
    
    private var jsonView: some View {
        Group {
            if let json = statusJSON {
                ScrollView {
                    Text(json)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
            } else {
                Form {
                    Section {
                        HStack {
                            Text("Status")
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.gray)
                                    .frame(width: 8, height: 8)
                                Text("Disconnected")
                                    .foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Text("Connection Status")
                    }
                }
            }
        }
    }
    
    // MARK: - Formatted View
    
    private var formattedView: some View {
        Group {
            if let status = olmStatusManager.socketStatus {
                Form {
                    // Overall Status Section
                    Section {
                        HStack {
                            Text("Agent")
                            Spacer()
                            Text(status.agent ?? "Unknown")
                                .foregroundColor(.secondary)
                        }
                        
                        if let version = status.version {
                            HStack {
                                Text("Version")
                                Spacer()
                                Text(version)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack {
                            Text("Status")
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(status.connected ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                Text(formatStatus(connected: status.connected, registered: status.registered))
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let orgId = status.orgId {
                            HStack {
                                Text("Organization")
                                Spacer()
                                Text(orgId)
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
                            Text("Peers")
                        }
                    } else {
                        Section {
                            Text("No peers connected")
                                .foregroundColor(.secondary)
                        } header: {
                            Text("Peers")
                        }
                    }
                }
            } else {
                Form {
                    Section {
                        HStack {
                            Text("Status")
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.gray)
                                    .frame(width: 8, height: 8)
                                Text("Disconnected")
                                    .foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Text("Connection Status")
                    }
                }
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
                if let endpoint = peer.endpoint {
                    Text(endpoint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Status indicators
            HStack(spacing: 12) {
                // Connected status
                HStack(spacing: 6) {
                    Circle()
                        .fill((peer.connected ?? false) ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(formatStatus(peer.connected ?? false))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    private func formatStatus(_ connected: Bool) -> String {
        return connected ? "Connected" : "Disconnected"
    }
}
#endif

