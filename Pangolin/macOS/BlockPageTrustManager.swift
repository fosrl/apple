import AppKit
import CryptoKit
import Foundation
import Security
import SwiftUI
import os.log

/// Lets the user approve trusting this Mac's DNS block page certificate authority.
///
/// When an org blocks a domain with a block page, olm answers lookups for it with a local
/// server that redirects browsers to the block page. Over HTTPS that server presents a
/// certificate signed by a CA that olm creates for this Mac only. olm runs in the system
/// extension, which can add the CA to the System keychain but cannot ask the user to approve
/// trusting it, so the app does that part: it marks the CA as trusted for TLS servers in the
/// admin trust domain (macOS asks for an administrator's password) and tells olm to check
/// again. Until then, blocked sites simply fail to load.
final class BlockPageTrustManager: ObservableObject {
    /// olm's block page state while the tunnel is up and the org uses block pages.
    @Published private(set) var status: BlockPageStatus?
    @Published private(set) var isWorking = false

    private let socketManager: SocketManager
    /// CAs the user was already asked about this session, by fingerprint.
    private var askedThisSession = Set<String>()
    private var askInFlight = false

    private static let declinedKey = "net.pangolin.Pangolin.BlockPage.declinedCAs"

    private let logger: PangolinLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return PangolinLog(subsystem: subsystem, category: "BlockPageTrust")
    }()

    init(socketManager: SocketManager) {
        self.socketManager = socketManager
    }

    /// Called with every status poll while connected, and with nil when the tunnel stops.
    /// Asks the user once per CA when olm reports that trusting it would turn block pages on.
    func observe(_ newStatus: BlockPageStatus?) {
        if status != newStatus {
            status = newStatus
        }
        guard newStatus?.needsTrust == true, !askInFlight, !isWorking else { return }
        askInFlight = true
        Task {
            await askIfNeeded()
            askInFlight = false
        }
    }

    /// Installs without asking first, from the settings button. Ignores an earlier "Not Now".
    func install() async {
        guard let cert = await fetchCA() else { return }
        await trust(cert)
    }

    /// Removes the trust the app added. olm then stops showing the block page and blocked
    /// sites fail to load, until the user allows it again.
    func remove() async {
        guard let cert = await fetchCA() else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let certificate = cert.certificate
            try await Task.detached { try Self.removeTrust(certificate) }.value
            Self.setDeclined(cert.fingerprint, true)
        } catch BlockPageTrustError.canceled {
            return
        } catch {
            showError("Pangolin could not remove the block page certificate.", error)
            return
        }
        await recheck()
    }

    // MARK: - Flow

    private func askIfNeeded() async {
        guard let cert = await fetchCA() else { return }
        guard !askedThisSession.contains(cert.fingerprint), !Self.isDeclined(cert.fingerprint)
        else { return }
        askedThisSession.insert(cert.fingerprint)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Show a page when a site is blocked?"
        alert.informativeText =
            "Your organization blocks some websites. To explain why a secure (HTTPS) site "
            + "won't open, Pangolin needs this Mac to trust a certificate that it created for "
            + "this Mac only and uses for nothing else. macOS will ask for an administrator's "
            + "password.\n\nIf you skip this, blocked sites just fail to load. You can change "
            + "this later in Settings > Connection."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            Self.setDeclined(cert.fingerprint, true)
            os_log("User declined to trust the block page certificate", log: logger, type: .info)
            return
        }
        await trust(cert)
    }

    private func trust(_ cert: FetchedCA) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let certificate = cert.certificate
            try await Task.detached { try Self.addTrust(certificate) }.value
            Self.setDeclined(cert.fingerprint, false)
            os_log("Trusted the block page certificate", log: logger, type: .info)
        } catch BlockPageTrustError.canceled {
            // The user closed the password prompt; asking again from Settings still works.
            return
        } catch {
            showError("Pangolin could not trust the block page certificate.", error)
            return
        }
        await recheck()
    }

    private func recheck() async {
        do {
            let newStatus = try await socketManager.recheckBlockPage()
            status = newStatus
            if !newStatus.trusted {
                os_log(
                    "Block page still not trusted: %{public}@", log: logger, type: .error,
                    newStatus.error ?? "unknown")
            }
        } catch {
            // The next status poll picks up the new state anyway.
            os_log(
                "Block page recheck failed: %{public}@", log: logger, type: .error,
                error.localizedDescription)
        }
    }

    nonisolated private struct FetchedCA {
        let certificate: SecCertificate
        let fingerprint: String
    }

    private func fetchCA() async -> FetchedCA? {
        do {
            let pem = try await socketManager.getBlockPageCA()
            guard let der = Self.derFromPEM(pem),
                let certificate = SecCertificateCreateWithData(nil, der as CFData)
            else {
                os_log(
                    "olm returned a block page certificate that could not be read", log: logger,
                    type: .error)
                return nil
            }
            let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            return FetchedCA(certificate: certificate, fingerprint: fingerprint)
        } catch {
            os_log(
                "Could not fetch the block page certificate: %{public}@", log: logger,
                type: .error, error.localizedDescription)
            return nil
        }
    }

    private func showError(_ message: String, _ error: Error) {
        os_log(
            "%{public}@ %{public}@", log: logger, type: .error, message,
            error.localizedDescription)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Declined CAs

    private static func isDeclined(_ fingerprint: String) -> Bool {
        UserDefaults.standard.stringArray(forKey: declinedKey)?.contains(fingerprint) == true
    }

    private static func setDeclined(_ fingerprint: String, _ declined: Bool) {
        var list = UserDefaults.standard.stringArray(forKey: declinedKey) ?? []
        list.removeAll { $0 == fingerprint }
        if declined {
            list.append(fingerprint)
        }
        UserDefaults.standard.set(list, forKey: declinedKey)
    }

    // MARK: - Security framework

    nonisolated private static func derFromPEM(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let base64 = text
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: base64)
    }

    /// Trusts the CA as a root for TLS servers only, for every user on this Mac (admin domain),
    /// so browsers and olm's own check, which runs as root, accept it. macOS shows its
    /// administrator password prompt. olm has already put the certificate in the System
    /// keychain.
    nonisolated private static func addTrust(_ cert: SecCertificate) throws {
        let settings: [[String: Any]] = [
            [
                kSecTrustSettingsPolicy as String: SecPolicyCreateSSL(true, nil),
                kSecTrustSettingsResult as String: NSNumber(
                    value: SecTrustSettingsResult.trustRoot.rawValue),
            ]
        ]
        try check(SecTrustSettingsSetTrustSettings(cert, .admin, settings as CFArray))
    }

    nonisolated private static func removeTrust(_ cert: SecCertificate) throws {
        let status = SecTrustSettingsRemoveTrustSettings(cert, .admin)
        if status == errSecItemNotFound {
            return
        }
        try check(status)
    }

    nonisolated private static func check(_ status: OSStatus) throws {
        if status == errSecSuccess {
            return
        }
        // errAuthorizationCanceled imports as Int.
        if status == OSStatus(errAuthorizationCanceled) || status == errSecUserCanceled {
            throw BlockPageTrustError.canceled
        }
        throw BlockPageTrustError.security(status)
    }
}

nonisolated enum BlockPageTrustError: LocalizedError {
    case canceled
    case security(OSStatus)

    var errorDescription: String? {
        switch self {
        case .canceled:
            return "Canceled."
        case .security(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "\(text) (\(status))"
        }
    }
}

/// Settings > Connection row for the block page certificate. Shown only while olm reports
/// that the org uses block pages.
struct BlockPageTrustSection: View {
    @ObservedObject var manager: BlockPageTrustManager

    var body: some View {
        if let status = manager.status {
            Section(header: Text("Block Page")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show a Page for Blocked Sites")
                            .font(.system(size: 13))
                        Text(description(status))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if manager.isWorking {
                        ProgressView().controlSize(.small)
                    } else if status.trusted {
                        Button("Remove...") { Task { await manager.remove() } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else if status.needsTrust == true {
                        Button("Allow...") { Task { await manager.install() } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func description(_ status: BlockPageStatus) -> String {
        if status.trusted {
            return "Blocked sites show a page from your organization. This Mac trusts a "
                + "certificate that Pangolin created for it only."
        }
        if status.needsTrust == true {
            return "Blocked sites fail to load. To show a page instead, this Mac needs to "
                + "trust a certificate that Pangolin created for it only."
        }
        return status.error ?? "Blocked sites fail to load."
    }
}
