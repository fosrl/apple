import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import os.log

#if os(macOS)
/// Installs the latest Pangolin CLI into /usr/local/bin, where its install
/// script (get-cli.sh) puts it. Like that script, it asks the Fossorial API for
/// the latest version and the release assets' checksums, then downloads the
/// asset from that version's GitHub release and checks it. macOS asks
/// for an administrator's password when that directory isn't writable, as
/// Windows asks through UAC and Linux through polkit.
final class CLIInstaller: ObservableObject {
    static let shared = CLIInstaller()

    enum Phase: Equatable {
        case confirm
        case installing
        case done
        case error(String)
    }

    @Published private(set) var phase: Phase = .confirm
    @Published private(set) var isInstalled = false

    static let installDirectory = "/usr/local/bin"
    static let binaryName = "pangolin"
    private static let releaseAPIURL = URL(string: "https://api.fossorial.io/api/v1/versions/cli")!
    private static let releaseDownloadURL = "https://github.com/fosrl/cli/releases/download"
    private static let userAgent = "pangolin-client-cli-installer"

    private static let logger: PangolinLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return PangolinLog(subsystem: subsystem, category: "CLIInstaller")
    }()

    private init() {
        refreshInstalled()
    }

    var isInstalling: Bool { phase == .installing }

    /// Starts the window over at the confirmation, unless an install is running.
    func resetForPresentation() {
        if phase != .installing {
            phase = .confirm
        }
    }

    func refreshInstalled() {
        isInstalled = Self.findInstalledCLI() != nil
    }

    func install() {
        guard phase != .installing else { return }
        phase = .installing
        os_log("Starting Pangolin CLI install", log: Self.logger, type: .info)

        Task {
            do {
                try await Self.performInstall()
                phase = .done
            } catch CLIInstallError.cancelled {
                os_log("Pangolin CLI install cancelled", log: Self.logger, type: .info)
                phase = .confirm
            } catch {
                os_log(
                    "Failed to install Pangolin CLI: %{public}@",
                    log: Self.logger, type: .error, error.localizedDescription)
                phase = .error(error.localizedDescription)
            }
            refreshInstalled()
        }
    }

    // MARK: - Detection

    /// The pangolin binary a new terminal would find, if any. Apps launch with
    /// a minimal PATH, so this looks where a login shell's PATH would: the
    /// directories in /etc/paths and /etc/paths.d, plus common user and
    /// Homebrew directories.
    nonisolated static func findInstalledCLI() -> String? {
        let fm = FileManager.default
        var dirs: [String] = [installDirectory, "/opt/homebrew/bin"]
        var pathFiles = ["/etc/paths"]
        if let entries = try? fm.contentsOfDirectory(atPath: "/etc/paths.d") {
            pathFiles += entries.sorted().map { "/etc/paths.d/\($0)" }
        }
        for file in pathFiles {
            guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            dirs += contents.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let home = fm.homeDirectoryForCurrentUser.path
        dirs += ["\(home)/.local/bin", "\(home)/bin", "\(home)/go/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }

        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(binaryName)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Install

    private static func performInstall() async throws {
        let asset = "pangolin-cli_darwin_\(isAppleSilicon() ? "arm64" : "amd64")"
        let release = try await latestRelease()
        guard let digest = release.assetDigests[asset]?.lowercased(), isSHA256Hex(digest) else {
            throw CLIInstallError.message(
                "CLI \(release.version) has no published checksum for \(asset).")
        }
        guard let url = URL(string: "\(releaseDownloadURL)/\(release.version)/\(asset)") else {
            throw CLIInstallError.message("Couldn't build the download URL for CLI \(release.version).")
        }
        os_log(
            "Installing Pangolin CLI %{public}@ from %{public}@",
            log: logger, type: .info, release.version, url.absoluteString)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pangolin-cli-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let downloaded = tempDir.appendingPathComponent(binaryName)
        try await download(url, to: downloaded)
        try verifyChecksum(downloaded, expected: digest)
        try checkMachO(downloaded)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloaded.path)
        removexattr(downloaded.path, "com.apple.quarantine", 0)

        try installBinary(from: downloaded)
        os_log(
            "Installed Pangolin CLI %{public}@ at %{public}@/%{public}@",
            log: logger, type: .info, release.version, installDirectory, binaryName)
    }

    /// Copies the binary into place: directly when this user can write to
    /// /usr/local/bin, otherwise as root after an administrator authenticates.
    private static func installBinary(from source: URL) throws {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: installDirectory).appendingPathComponent(binaryName)

        if fm.isWritableFile(atPath: installDirectory) {
            // Copy beside the target, then swap it in, so the target is never half written.
            let staged = URL(fileURLWithPath: installDirectory)
                .appendingPathComponent(".\(binaryName)-\(UUID().uuidString)")
            do {
                try fm.copyItem(at: source, to: staged)
                if fm.fileExists(atPath: target.path) {
                    _ = try fm.replaceItemAt(target, withItemAt: staged)
                } else {
                    try fm.moveItem(at: staged, to: target)
                }
                return
            } catch {
                try? fm.removeItem(at: staged)
                throw CLIInstallError.message("Failed to install \(target.path): \(error.localizedDescription)")
            }
        }

        let command =
            "/bin/mkdir -p \(shellQuote(installDirectory)) && "
            + "/usr/bin/install -m 0755 \(shellQuote(source.path)) \(shellQuote(target.path))"
        try runAsAdministrator(command)
    }

    /// Runs a shell command as root. macOS shows its standard password prompt
    /// on behalf of this app.
    private static func runAsAdministrator(_ command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt "
            + "\"Pangolin wants to install the Pangolin CLI.\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            throw CLIInstallError.message("Couldn't prepare the install command.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return }

        if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 {
            throw CLIInstallError.cancelled
        }
        let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "An unknown error occurred."
        throw CLIInstallError.message(message)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Release

    private struct Release {
        let version: String
        let assetDigests: [String: String]
    }

    private struct ReleaseResponse: Decodable {
        struct Data: Decodable {
            let latestVersion: String
            let assetDigests: [String: String]?
        }

        let data: Data
    }

    private static func latestRelease() async throws -> Release {
        var request = URLRequest(url: releaseAPIURL)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CLIInstallError.message("Failed to get the latest CLI version: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CLIInstallError.message("CLI version API returned \(http.statusCode).")
        }
        let body: ReleaseResponse
        do {
            body = try JSONDecoder().decode(ReleaseResponse.self, from: data)
        } catch {
            throw CLIInstallError.message("Failed to read the latest CLI version.")
        }

        // Only the characters get-cli.sh accepts, so the version can't change
        // the shape of the download URL.
        var version = body.data.latestVersion
        if version.hasPrefix("v") { version.removeFirst() }
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.+-")
        guard !version.isEmpty, version.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CLIInstallError.message("CLI version API returned an invalid version.")
        }
        return Release(version: version, assetDigests: body.data.assetDigests ?? [:])
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func verifyChecksum(_ url: URL, expected: String) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw CLIInstallError.message(
                "The downloaded CLI doesn't match its published checksum; it may be corrupted or tampered with.")
        }
    }

    private static func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await URLSession.shared.download(for: request)
        } catch {
            throw CLIInstallError.message("Failed to download the CLI: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CLIInstallError.message("CLI download failed with \(http.statusCode).")
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Rejects a download that isn't a macOS executable, such as an error page.
    private static func checkMachO(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4) ?? Data()
        let known: Set<Data> = [
            Data([0xCF, 0xFA, 0xED, 0xFE]),  // 64-bit Mach-O
            Data([0xCA, 0xFE, 0xBA, 0xBE]),  // universal binary
        ]
        guard known.contains(magic) else {
            throw CLIInstallError.message("The downloaded CLI isn't a macOS executable.")
        }
    }

    /// True on Apple silicon, including when this app runs under Rosetta.
    private static func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}

enum CLIInstallError: LocalizedError {
    case cancelled
    case message(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "The install was cancelled."
        case .message(let message): return message
        }
    }
}
#endif
