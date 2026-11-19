import Combine
import Foundation

/// A log message shown in the Logs view.
nonisolated struct LogEntry: Identifiable, Hashable, Sendable {
    /// Increases with every message read, so it also orders messages.
    let id: Int
    /// `2006-01-02 15:04:05.000`, local time.
    let stamp: String
    let level: String
    let message: String

    /// How Copy and Save write the message.
    var exportLine: String {
        "\(stamp) [\(level)] \(message)\n"
    }

    static func exportText(_ entries: [LogEntry]) -> String {
        entries.map(\.exportLine).joined()
    }

    static func exportFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        return "pangolin-log-\(formatter.string(from: date)).txt"
    }
}

/// The messages in the log files, tailed while a Logs view is open. Shared so the messages, and
/// Clear, last while the app runs.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    /// Most messages kept; older ones are dropped.
    static let maxEntries = 10_000
    /// Most messages loaded from the files when first shown.
    static let maxInitialEntries = 2_000

    @Published private(set) var entries: [LogEntry] = []

    private let reader = LogFilesReader(urls: LogFiles.all)
    private var nextID = 1
    private var openViews = 0
    private var loaded = false
    private var reading = false
    private var timer: Timer?

    func viewAppeared() {
        openViews += 1
        guard openViews == 1 else { return }
        if loaded {
            poll()
        } else {
            loaded = true
            reading = true
            reader.loadInitial(limit: Self.maxInitialEntries) { raw in
                Task { @MainActor in
                    self.reading = false
                    self.append(raw)
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in LogStore.shared.poll() }
        }
    }

    func viewDisappeared() {
        openViews = max(openViews - 1, 0)
        guard openViews == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    /// Clears the messages shown. The files are kept, and new messages keep appearing.
    func clear() {
        entries.removeAll()
    }

    private func poll() {
        guard !reading else { return }
        reading = true
        reader.readNew { raw in
            Task { @MainActor in
                self.reading = false
                self.append(raw)
            }
        }
    }

    private func append(_ raw: [RawLogEntry]) {
        guard !raw.isEmpty else { return }
        var added: [LogEntry] = []
        added.reserveCapacity(raw.count)
        for r in raw {
            added.append(LogEntry(id: nextID, stamp: r.stamp, level: r.level, message: r.message))
            nextID += 1
        }
        var next = entries + added
        if next.count > Self.maxEntries {
            next.removeFirst(next.count - Self.maxEntries)
        }
        entries = next
    }
}

nonisolated struct RawLogEntry: Sendable {
    var stamp: String
    var level: String
    var message: String
}

/// Reads the log files on a background queue.
nonisolated final class LogFilesReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.pangolin.Pangolin.LogFilesReader", qos: .utility)
    // Only used on `queue`.
    private let tailers: [LogFileTailer]

    init(urls: [URL]) {
        tailers = urls.map(LogFileTailer.init)
    }

    /// The last `limit` messages of all files, including their backups, oldest first.
    func loadInitial(limit: Int, completion: @escaping @Sendable ([RawLogEntry]) -> Void) {
        queue.async {
            let entries = Self.merge(self.tailers.map { $0.loadInitial() })
            completion(Array(entries.suffix(limit)))
        }
    }

    /// Messages written since the last read, oldest first.
    func readNew(completion: @escaping @Sendable ([RawLogEntry]) -> Void) {
        queue.async {
            completion(Self.merge(self.tailers.map { $0.readNew() }))
        }
    }

    /// Merges the files' messages by time. Each file is already in order.
    private static func merge(_ lists: [[RawLogEntry]]) -> [RawLogEntry] {
        let nonEmpty = lists.filter { !$0.isEmpty }
        if nonEmpty.count <= 1 { return nonEmpty.first ?? [] }
        return nonEmpty.enumerated()
            .flatMap { list in list.element.enumerated().map { (list.offset, $0.offset, $0.element) } }
            .sorted { ($0.2.stamp, $0.0, $0.1) < ($1.2.stamp, $1.0, $1.1) }
            .map(\.2)
    }
}

/// Follows one log file across rotations.
nonisolated final class LogFileTailer {
    private let url: URL
    /// The file read so far, and how much of it.
    private var fileNumber: UInt64?
    private var offset: UInt64 = 0
    /// The start of a line not yet ended.
    private var partial = Data()

    init(url: URL) {
        self.url = url
    }

    func loadInitial() -> [RawLogEntry] {
        let backup = LogFiles.backupURL(for: url)
        var data = (try? Data(contentsOf: backup)) ?? Data()
        partial = Data()
        offset = 0
        fileNumber = Self.fileNumber(of: url)
        if let current = read(url, from: 0) {
            data.append(current)
            offset = UInt64(current.count)
        }
        return parse(data)
    }

    func readNew() -> [RawLogEntry] {
        guard let number = Self.fileNumber(of: url) else { return [] }
        var data = Data()
        if let fileNumber, number != fileNumber {
            // Rotated: finish the old file, now the backup, then start the new one.
            let backup = LogFiles.backupURL(for: url)
            if Self.fileNumber(of: backup) == fileNumber, let rest = read(backup, from: offset) {
                data.append(rest)
            }
            offset = 0
        }
        fileNumber = number
        if let new = read(url, from: offset) {
            if new.isEmpty, Self.size(of: url).map({ $0 < offset }) == true {
                // Truncated in place.
                offset = 0
                partial = Data()
                if let all = read(url, from: 0) {
                    data.append(all)
                    offset = UInt64(all.count)
                }
            } else {
                data.append(new)
                offset += UInt64(new.count)
            }
        }
        return parse(data)
    }

    private func read(_ url: URL, from offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }

    /// Parses the complete lines in `partial` + `data`, keeping an unfinished last line.
    private func parse(_ data: Data) -> [RawLogEntry] {
        var buffer = partial
        buffer.append(data)
        guard let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) else {
            partial = buffer
            return []
        }
        partial = Data(buffer[buffer.index(after: lastNewline)...])
        let text = String(decoding: buffer[..<lastNewline], as: UTF8.self)

        var entries: [RawLogEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let entry = Self.parseHeader(line) {
                entries.append(entry)
            } else if !entries.isEmpty {
                // A further line of a multi-line message.
                let continuation = line.hasPrefix("\t") ? line.dropFirst() : line
                entries[entries.count - 1].message += "\n" + continuation
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                entries.append(RawLogEntry(
                    stamp: LogLineFormat.stamp(Date()), level: "UNKNOWN", message: String(line)))
            }
        }
        return entries
    }

    /// Parses `2006-01-02 15:04:05.000 LEVEL message`.
    private static func parseHeader(_ line: Substring) -> RawLogEntry? {
        let stampLength = LogLineFormat.stampLength
        let chars = Array(line.utf8.prefix(stampLength + 1))
        guard chars.count == stampLength + 1,
            chars[4] == UInt8(ascii: "-"), chars[7] == UInt8(ascii: "-"),
            chars[10] == UInt8(ascii: " "), chars[13] == UInt8(ascii: ":"),
            chars[16] == UInt8(ascii: ":"), chars[19] == UInt8(ascii: "."),
            chars[stampLength] == UInt8(ascii: " ")
        else { return nil }
        let stamp = line.prefix(stampLength)
        let rest = line.dropFirst(stampLength + 1)
        guard let space = rest.firstIndex(of: " ") else {
            return RawLogEntry(stamp: String(stamp), level: String(rest), message: "")
        }
        return RawLogEntry(
            stamp: String(stamp),
            level: String(rest[..<space]),
            message: String(rest[rest.index(after: space)...]))
    }

    private static func fileNumber(of url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private static func size(of url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value
    }
}
