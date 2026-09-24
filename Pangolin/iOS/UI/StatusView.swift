import SwiftUI
import UIKit

enum DisplayMode: String, CaseIterable {
    case formatted = "Formatted"
    case json = "JSON"
}

struct StatusView: View {
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
        NavigationStack {
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
            .navigationTitle("Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if displayMode == .json {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            UIPasteboard.general.string = displayedJSON
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
                olmStatusManager.startPolling()
            }
            .onDisappear {
                olmStatusManager.stopPolling()
            }
            .sheet(isPresented: siteSheetPresented) {
                if let selectedSiteID {
                    SiteStatusSheet(siteID: selectedSiteID, olmStatusManager: olmStatusManager)
                }
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
                .font(.system(.caption, design: .monospaced))
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
