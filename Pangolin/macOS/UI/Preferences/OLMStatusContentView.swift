import SwiftUI
import AppKit

enum DisplayMode: String, CaseIterable {
    case formatted = "Formatted"
    case json = "JSON"
}

struct OLMStatusContentView: View {
    @ObservedObject var olmStatusManager: OLMStatusManager
    @AppStorage("net.pangolin.Pangolin.statusDisplayMode") private var displayMode: DisplayMode = .formatted
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

    private var displayedJSON: String {
        statusJSON ?? Self.placeholderJSON
    }

    private static let placeholderJSON = """
    {
      "connected": false
    }
    """
    
    var body: some View {
        ScrollView {
            Form {
                Section {
                    Picker(selection: $displayMode) {
                        ForEach(DisplayMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    } label: {
                        Text("Display Mode")
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("View")
                }

                if displayMode == .json {
                    jsonContent
                } else {
                    formattedContent
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            if displayMode == .json {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(displayedJSON, forType: .string)
                        showCopyConfirmation = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showCopyConfirmation = false
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
    
    // MARK: - JSON View
    
    private var jsonContent: some View {
        Section {
            Text(displayedJSON)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            Text("JSON")
        }
    }
    
    // MARK: - Formatted View
    
    @ViewBuilder
    private var formattedContent: some View {
        if let status = olmStatusManager.socketStatus {
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

            if status.exitNode != nil || !(status.peers?.isEmpty ?? true) {
                Section {
                    if let exitNode = status.exitNode {
                        PeerRowView(name: "Pangolin Server", endpoint: exitNode.endpoint, connected: exitNode.connected)
                    }
                    if let peers = status.peers {
                        ForEach(Array(peers.keys.sorted()), id: \.self) { peerKey in
                            if let peer = peers[peerKey] {
                                PeerRowView(name: peer.name ?? "Unknown", endpoint: peer.endpoint, connected: peer.connected ?? false)
                            }
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
        } else {
            disconnectedSection
        }
    }

    private var disconnectedSection: some View {
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
    let name: String
    let endpoint: String?
    let connected: Bool

    var body: some View {
        HStack {
            // Peer name
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13))
                if let endpoint = endpoint {
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
                        .fill(connected ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(formatStatus(connected))
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

