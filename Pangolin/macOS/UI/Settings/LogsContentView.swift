import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Logs page, opened from About: messages from the app and the tunnel, newest at the bottom, with
/// copy and save, like the Logs tab of the Windows and Linux clients.
struct LogsContentView: View {
    @ObservedObject private var store = LogStore.shared
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 12) {
            LogTableView(entries: store.entries, onSave: save)
                .overlay {
                    if store.entries.isEmpty {
                        Text("No log messages")
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )

            HStack(spacing: 8) {
                Text(countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { store.clear() }
                Button("Save…") { save() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .onAppear { store.viewAppeared() }
        .onDisappear { store.viewDisappeared() }
        .alert(
            "Save Failed",
            isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var countText: String {
        let count = store.entries.count
        return "\(count.formatted()) \(count == 1 ? "message" : "messages")"
    }

    /// Asks for a file and writes all messages shown to it.
    private func save() {
        let text = LogEntry.exportText(store.entries)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = LogEntry.exportFileName()
        panel.allowedContentTypes = [.plainText]
        panel.message = "Export log to file"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                saveError = "Failed to write file: \(error.localizedDescription)"
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }
}

// MARK: - Table

/// A Time / Level / Message table of log messages that stays scrolled to the newest message
/// unless the user scrolls up or selects several messages.
private struct LogTableView: NSViewRepresentable {
    let entries: [LogEntry]
    let onSave: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = LogNSTableView()
        tableView.coordinator = context.coordinator
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = []
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            if column != .message {
                tableColumn.resizingMask = .userResizingMask
            }
            tableView.addTableColumn(tableColumn)
        }

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        context.coordinator.tableView = tableView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onSave = onSave
        context.coordinator.update(entries)
    }

    enum Column: CaseIterable {
        case time, level, message

        var identifier: NSUserInterfaceItemIdentifier {
            switch self {
            case .time: return NSUserInterfaceItemIdentifier("time")
            case .level: return NSUserInterfaceItemIdentifier("level")
            case .message: return NSUserInterfaceItemIdentifier("message")
            }
        }

        var title: String {
            switch self {
            case .time: return "Time"
            case .level: return "Level"
            case .message: return "Message"
            }
        }

        var width: CGFloat {
            switch self {
            case .time: return 180
            case .level: return 64
            case .message: return 400
            }
        }

        var minWidth: CGFloat {
            switch self {
            case .time: return 80
            case .level: return 40
            case .message: return 100
            }
        }
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// Within this many rows of the bottom counts as at the bottom.
    static let autoScrollRows: CGFloat = 10

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?
        var onSave: () -> Void = {}
        private var entries: [LogEntry] = []
        private var longestMessage = 0

        func update(_ newEntries: [LogEntry]) {
            guard let tableView else { return }
            let old = entries
            guard newEntries.first?.id != old.first?.id || newEntries.last?.id != old.last?.id
                || newEntries.count != old.count
            else { return }

            let stick = old.isEmpty || (isNearBottom && tableView.selectedRowIndexes.count <= 1)
            entries = newEntries

            if !old.isEmpty, newEntries.count > old.count, newEntries.first?.id == old.first?.id {
                // Only appended.
                tableView.insertRows(
                    at: IndexSet(integersIn: old.count..<newEntries.count), withAnimation: [])
                updateMessageWidth(newEntries[old.count...])
            } else {
                let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { old[safe: $0]?.id })
                longestMessage = 0
                updateMessageWidth(newEntries[...])
                tableView.reloadData()
                let rows = IndexSet(
                    newEntries.indices.filter { selectedIDs.contains(newEntries[$0].id) })
                tableView.selectRowIndexes(rows, byExtendingSelection: false)
            }

            if stick, !newEntries.isEmpty {
                tableView.scrollRowToVisible(newEntries.count - 1)
            }
        }

        private var isNearBottom: Bool {
            guard let scrollView, let documentView = scrollView.documentView else { return true }
            let visible = scrollView.contentView.bounds
            let threshold = LogTableView.autoScrollRows * (tableView?.rowHeight ?? 20)
            return documentView.frame.height - visible.maxY <= threshold
        }

        /// Widens the message column to fit the longest message, so long lines scroll
        /// horizontally instead of being cut off.
        private func updateMessageWidth(_ added: ArraySlice<LogEntry>) {
            guard let column = tableView?.tableColumn(withIdentifier: Column.message.identifier)
            else { return }
            let longest = added.reduce(0) { max($0, $1.message.firstLine.count) }
            if added.startIndex == 0 {
                longestMessage = longest
            } else {
                longestMessage = max(longestMessage, longest)
            }
            let charWidth = ("M" as NSString).size(withAttributes: [.font: LogTableView.font]).width
            column.minWidth = max(Column.message.minWidth, CGFloat(longestMessage) * charWidth + 16)
            column.width = max(column.width, column.minWidth)
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            guard let tableColumn, let entry = entries[safe: row] else { return nil }
            let identifier = tableColumn.identifier
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? NSTableCellView
            {
                cell = reused
            } else {
                cell = Self.makeCell(identifier: identifier)
            }
            guard let textField = cell.textField else { return cell }
            switch identifier {
            case Column.time.identifier:
                textField.stringValue = entry.stamp
                textField.textColor = .secondaryLabelColor
            case Column.level.identifier:
                textField.stringValue = entry.level
                textField.textColor = Self.levelColor(entry.level)
            default:
                textField.stringValue = String(entry.message.firstLine)
                textField.textColor = .labelColor
                textField.toolTip = entry.message.contains("\n") ? entry.message : nil
            }
            return cell
        }

        private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.font = LogTableView.font
            textField.lineBreakMode = identifier == Column.message.identifier
                ? .byClipping : .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private static func levelColor(_ level: String) -> NSColor {
            switch level.uppercased() {
            case "ERROR", "FATAL": return .systemRed
            case "WARN", "WARNING": return .systemOrange
            default: return .secondaryLabelColor
            }
        }

        // MARK: Copy, select all, save

        func copySelection() {
            guard let tableView else { return }
            let selected = tableView.selectedRowIndexes.compactMap { entries[safe: $0] }
            guard !selected.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(LogEntry.exportText(selected), forType: .string)
        }

        @objc func copyFromMenu(_ sender: Any?) {
            copySelection()
        }

        @objc func selectAllFromMenu(_ sender: Any?) {
            tableView?.selectAll(nil)
        }

        @objc func saveFromMenu(_ sender: Any?) {
            onSave()
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let tableView else { return }
            // Right-clicking a message outside the selection selects it, as in Finder.
            let clicked = tableView.clickedRow
            if clicked >= 0, !tableView.selectedRowIndexes.contains(clicked) {
                tableView.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            }

            menu.removeAllItems()
            let copy = NSMenuItem(title: "Copy", action: #selector(copyFromMenu), keyEquivalent: "c")
            copy.target = self
            copy.isEnabled = !tableView.selectedRowIndexes.isEmpty
            let selectAll = NSMenuItem(
                title: "Select All", action: #selector(selectAllFromMenu), keyEquivalent: "a")
            selectAll.target = self
            selectAll.isEnabled = tableView.selectedRowIndexes.count < entries.count
            let save = NSMenuItem(
                title: "Save to File…", action: #selector(saveFromMenu), keyEquivalent: "s")
            save.target = self
            menu.autoenablesItems = false
            menu.items = [copy, selectAll, .separator(), save]
        }
    }
}

/// Handles Copy and Save from the keyboard, whether or not the main menu has those items.
private final class LogNSTableView: NSTableView {
    weak var coordinator: LogTableView.Coordinator?

    @objc func copy(_ sender: Any?) {
        coordinator?.copySelection()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "c":
            coordinator?.copySelection()
            return true
        case "a":
            selectAll(nil)
            return true
        case "s":
            coordinator?.onSave()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

private extension String {
    var firstLine: Substring {
        prefix { $0 != "\n" }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
