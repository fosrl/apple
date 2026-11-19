import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Messages from the app and the tunnel, newest at the bottom, with share and copy, like the Logs
/// tab of the other Pangolin clients.
struct LogsView: View {
    @ObservedObject private var store = LogStore.shared
    /// Whether the newest message is on screen, so new messages scroll into view.
    @State private var atBottom = true

    private static let bottomID = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.entries) { entry in
                        LogRow(entry: entry)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: store.entries.last?.id) { _, _ in
                guard atBottom else { return }
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
        .overlay {
            if store.entries.isEmpty {
                ContentUnavailableView(
                    "No Log Messages",
                    systemImage: "doc.text",
                    description: Text("Messages from Pangolin and the tunnel appear here.")
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text(countText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.bar)
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(
                    item: LogExport(entries: store.entries),
                    preview: SharePreview("Pangolin Logs")
                )
                .disabled(store.entries.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = LogEntry.exportText(store.entries)
                    } label: {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }
                    .disabled(store.entries.isEmpty)
                    Button(role: .destructive) {
                        store.clear()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .disabled(store.entries.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .onAppear { store.viewAppeared() }
        .onDisappear { store.viewDisappeared() }
    }

    private var countText: String {
        let count = store.entries.count
        return "\(count.formatted()) \(count == 1 ? "message" : "messages")"
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                // The date is left out to fit; Copy and Share include it.
                Text(entry.stamp.dropFirst(11))
                    .foregroundStyle(.secondary)
                Text(entry.level)
                    .fontWeight(.semibold)
                    .foregroundStyle(levelColor)
            }
            .font(.caption2.monospaced())
            Text(entry.message)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        // Alternating rows; ids are consecutive, so this stays put as old messages are dropped.
        .background(entry.id.isMultiple(of: 2) ? Color(.secondarySystemBackground) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = entry.exportLine
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = entry.message
            } label: {
                Label("Copy Message", systemImage: "text.quote")
            }
        }
    }

    private var levelColor: Color {
        switch entry.level.uppercased() {
        case "ERROR", "FATAL": return .red
        case "WARN", "WARNING": return .orange
        default: return .secondary
        }
    }
}

/// The messages shown, shared as a text file.
private nonisolated struct LogExport: Transferable {
    let entries: [LogEntry]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { export in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(LogEntry.exportFileName())
            try LogEntry.exportText(export.entries).write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
