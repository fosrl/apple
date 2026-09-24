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
    @State private var selectedSiteID: String?
    
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
        .sheet(isPresented: siteSheetPresented) {
            if let selectedSiteID {
                SiteStatusSheet(siteID: selectedSiteID, olmStatusManager: olmStatusManager)
            }
        }
    }

    private var siteSheetPresented: Binding<Bool> {
        Binding(
            get: { selectedSiteID != nil },
            set: { isPresented in
                if !isPresented {
                    selectedSiteID = nil
                }
            }
        )
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

            let sites = SiteStatusItem.list(from: status)
            if !sites.isEmpty {
                Section {
                    ForEach(sites) { site in
                        SiteStatusRow(site: site) {
                            selectedSiteID = site.id
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

