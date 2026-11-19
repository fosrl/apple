import Foundation
import os.log

// Log messages go to the unified log (Console, `log stream`) and to a log file the app's Logs
// view reads. The app can't read the unified log back: `OSLogStore` only sees the current
// process, and most of what matters happens in the tunnel extension.
//
// Each process writes its own file so no file is shared between writers: the tunnel extension
// (Swift and Go) writes `tunnel.log`, the app writes `app.log`. Each file is rotated once it
// passes `LogFiles.maxFileSize`, keeping one backup (`tunnel.log.1`).

/// The severity written to the log file and shown in the Logs view.
nonisolated enum LogSeverity: String, Comparable, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"

    /// Messages below this are only sent to the unified log, as on the other Pangolin clients,
    /// whose default log level is info.
    static let minimumForFile: LogSeverity = .info

    init(_ type: OSLogType) {
        switch type {
        case .debug: self = .debug
        case .info, .default: self = .info
        case .error, .fault: self = .error
        default: self = .info
        }
    }

    /// Levels passed by Go through `goLogToOSLog`: 0=debug, 1=info, 2=warn, 3=error, 4=fault.
    init(goLevel: Int32) {
        switch goLevel {
        case 0: self = .debug
        case 1: self = .info
        case 2: self = .warn
        default: self = .error
        }
    }

    private var order: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    static func < (lhs: LogSeverity, rhs: LogSeverity) -> Bool {
        lhs.order < rhs.order
    }
}

/// Where the log files live.
nonisolated enum LogFiles {
    static let maxFileSize: UInt64 = 2 * 1024 * 1024

    /// Whether this process is the tunnel extension rather than the app.
    static let isTunnelProcess: Bool = {
        let ext = Bundle.main.bundleURL.pathExtension
        return ext == "appex" || ext == "systemextension"
    }()

    /// The file the tunnel extension writes.
    static var tunnelURL: URL? {
        #if os(macOS)
        // The system extension runs as root, so its app group container is root's. Write
        // somewhere the app (running as the user) can read instead.
        return URL(fileURLWithPath: "/Library/Logs/Pangolin/tunnel.log")
        #else
        return appGroupLogsDirectory?.appendingPathComponent("tunnel.log")
        #endif
    }

    /// The file the app writes.
    static var appURL: URL? {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Pangolin/app.log")
        #else
        return appGroupLogsDirectory?.appendingPathComponent("app.log")
        #endif
    }

    /// The files the Logs view shows, in no particular order.
    static var all: [URL] {
        [tunnelURL, appURL].compactMap { $0 }
    }

    static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("1")
    }

    #if os(iOS)
    private static var appGroupLogsDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.net.pangolin.Pangolin")?
            .appendingPathComponent("Logs", isDirectory: true)
    }
    #endif
}

/// The line format of the log files: `2006-01-02 15:04:05.000 LEVEL message`. Further lines of a
/// multi-line message start with a tab.
nonisolated enum LogLineFormat {
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Length of a formatted timestamp.
    static let stampLength = 23

    static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    static func format(date: Date, severity: LogSeverity, message: String) -> String {
        let body = message
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\n\t")
        return "\(stamp(date)) \(severity.rawValue) \(body)\n"
    }
}

/// Appends lines to this process's log file, rotating it when it gets too large.
nonisolated final class LogFileWriter: @unchecked Sendable {
    static let shared = LogFileWriter(
        url: LogFiles.isTunnelProcess ? LogFiles.tunnelURL : LogFiles.appURL)

    private let url: URL?
    private let queue = DispatchQueue(label: "net.pangolin.Pangolin.LogFileWriter", qos: .utility)
    // Only used on `queue`.
    private var handle: FileHandle?
    private var size: UInt64 = 0

    init(url: URL?) {
        self.url = url
    }

    func write(_ severity: LogSeverity, _ message: String) {
        guard severity >= LogSeverity.minimumForFile, url != nil else { return }
        let line = LogLineFormat.format(date: Date(), severity: severity, message: message)
        queue.async { self.append(line) }
    }

    private func append(_ line: String) {
        guard let url else { return }
        let data = Data(line.utf8)
        if handle == nil {
            open(url)
        }
        if handle != nil, size + UInt64(data.count) > LogFiles.maxFileSize {
            rotate(url)
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            size += UInt64(data.count)
        } catch {
            // Reopen on the next write, e.g. after the file was deleted.
            try? handle.close()
            self.handle = nil
        }
    }

    private func open(_ url: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            if !fm.fileExists(atPath: url.path) {
                // Readable by everyone: on macOS the tunnel runs as root and the app as the user.
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o644])
            }
            let handle = try FileHandle(forWritingTo: url)
            size = try handle.seekToEnd()
            self.handle = handle
        } catch {
            os_log(
                "Failed to open log file %{public}@: %{public}@",
                log: OSLog(subsystem: "net.pangolin.Pangolin", category: "LogFileWriter"),
                type: .error, url.path, error.localizedDescription)
        }
    }

    private func rotate(_ url: URL) {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let backup = LogFiles.backupURL(for: url)
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: url, to: backup)
        open(url)
    }
}

/// A log category whose messages also go to the log file. Pass it as `log:` to `os_log` in place
/// of an `OSLog`; the `os_log` overload below handles it.
nonisolated final class PangolinLog: Sendable {
    let osLog: OSLog
    let category: String

    init(subsystem: String, category: String) {
        self.osLog = OSLog(subsystem: subsystem, category: category)
        self.category = category
    }

    static let `default` = PangolinLog(
        subsystem: Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin", category: "General")
}

/// Logs to the unified log, like the `os_log` it overloads, and to the log file.
///
/// The message is formatted here rather than by `os_log`, so arguments are always public in the
/// unified log. The file holds the same text, so don't log secrets either way.
nonisolated func os_log(
    _ message: StaticString, log: PangolinLog, type: OSLogType = .default, _ args: CVarArg...
) {
    let format = message.description
        .replacingOccurrences(of: "%{public}", with: "%")
        .replacingOccurrences(of: "%{private}", with: "%")
    let text = args.isEmpty ? format : String(format: format, arguments: args)
    os_log("%{public}@", log: log.osLog, type: type, text)
    LogFileWriter.shared.write(LogSeverity(type), "[\(log.category)] \(text)")
}
