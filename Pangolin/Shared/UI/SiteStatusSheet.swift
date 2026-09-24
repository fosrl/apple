import SwiftUI

struct SiteStatusRow: View {
    let site: SiteStatusItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.name)
                        .font(rowFont)
                    if let endpoint = site.endpoint, !endpoint.isEmpty {
                        Text(endpoint)
                            .font(endpointFont)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(site.connected ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(site.connected ? "Connected" : "Disconnected")
                        .font(rowFont)
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private var rowFont: Font {
        #if os(macOS)
        .system(size: 13)
        #else
        .body
        #endif
    }

    private var endpointFont: Font {
        #if os(macOS)
        .system(size: 13)
        #else
        .caption
        #endif
    }
}

struct SiteStatusSheet: View {
    let siteID: String
    @ObservedObject var olmStatusManager: OLMStatusManager
    @Environment(\.dismiss) private var dismiss

    private var site: SiteStatusItem? {
        guard let status = olmStatusManager.socketStatus else { return nil }
        return SiteStatusItem.list(from: status).first { $0.id == siteID }
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            sheetBody
                .navigationTitle(site?.name ?? "Site")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        VStack(alignment: .leading, spacing: 16) {
            Text(site?.name ?? "Site")
                .font(.headline)
            sheetBody
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        #endif
    }

    @ViewBuilder
    private var sheetBody: some View {
        if let site {
            VStack(alignment: .leading, spacing: 14) {
                detailRow(label: "Site", value: site.name)
                statusRow(connected: site.connected)
                detailRow(label: "Connection", value: site.connection ?? "—")
                detailRow(label: "Endpoint", value: display(site.endpoint))
                detailRow(label: "Last Seen", value: displayLastSeen(site.lastSeen))
            }
            #if os(iOS)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #endif
        } else {
            Text("This site is no longer in the status response.")
                .foregroundColor(.secondary)
                #if os(iOS)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                #endif
        }
    }

    private func statusRow(connected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Status")
                .font(labelFont)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(connected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(connected ? "Connected" : "Disconnected")
                    .font(valueFont)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(labelFont)
            Spacer(minLength: 16)
            Text(value)
                .font(valueFont)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func display(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }

    private func displayLastSeen(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        guard let date = Self.parseDate(value) else { return value }
        return Self.relativeTime(since: date)
    }

    private static func relativeTime(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }
        return "\(hours / 24)d ago"
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        return nil
    }

    private var labelFont: Font {
        #if os(macOS)
        .system(size: 13)
        #else
        .body
        #endif
    }

    private var valueFont: Font {
        #if os(macOS)
        .system(size: 13)
        #else
        .body
        #endif
    }
}
