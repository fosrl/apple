import Darwin
import Foundation
import os.log

#if os(macOS)
/// Companion mode: the Pangolin CLI signs in with this app's session. It reads
/// account details from accounts.json and asks the app for the secrets, which
/// live in this app's Keychain items, over a Unix socket next to accounts.json.
///
/// The protocol matches the Windows and Linux desktop apps: the request is a
/// little-endian uint32 length and the Pangolin user id; the reply is a uint32
/// status, a uint32 length and a payload (secrets JSON, or an error message).
///
/// Only processes running as this user, or root (the CLI under sudo), may ask.
nonisolated final class CLISecretsServer: @unchecked Sendable {
    static let socketFileName = "cli.sock"

    private enum Status: UInt32 {
        case ok = 0
        case notFound = 1
        case error = 2
    }

    private struct Secrets: Encodable {
        let sessionToken: String?
        let olmId: String?
        let olmSecret: String?
    }

    private static let maxUserIdLength: UInt32 = 256
    private static let ioTimeoutSeconds = 5

    private let secretManager: SecretManager
    private let socketPath: String
    private let acceptQueue = DispatchQueue(label: "net.pangolin.Pangolin.cli-secrets.accept")
    private let connectionQueue = DispatchQueue(
        label: "net.pangolin.Pangolin.cli-secrets.conn", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return OSLog(subsystem: subsystem, category: "CLISecretsServer")
    }()

    init(secretManager: SecretManager, socketPath: String) {
        self.secretManager = secretManager
        self.socketPath = socketPath
    }

    @MainActor static var defaultSocketPath: String {
        AccountStoreLocation.url
            .deletingLastPathComponent()
            .appendingPathComponent(socketFileName)
            .path
    }

    /// Starts listening. Safe to call more than once.
    func start() {
        acceptQueue.async { [self] in
            guard acceptSource == nil else { return }
            do {
                try listen()
                os_log("CLI secrets server listening on %{public}@", log: logger, type: .info, socketPath)
            } catch {
                os_log(
                    "CLI secrets server failed to start: %{public}@", log: logger, type: .error,
                    String(describing: error))
                closeListener()
            }
        }
    }

    /// Stops listening and removes the socket file.
    func stop() {
        acceptQueue.sync { [self] in
            closeListener()
        }
    }

    // MARK: - Listening

    private struct POSIXFailure: Error, CustomStringConvertible {
        let call: String
        let code: Int32
        var description: String { "\(call): \(String(cString: strerror(code)))" }
    }

    private func listen() throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            throw POSIXFailure(call: "socket path too long (\(socketPath))", code: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: pathBytes)
            buf[pathBytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXFailure(call: "socket", code: errno) }
        listenFD = fd

        // A socket left behind by a previous run (e.g. a crash) blocks bind.
        unlink(socketPath)

        // Create the socket owner-only from the start, then tighten it again
        // in case the umask was ignored.
        let oldMask = umask(0o077)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let bindErrno = errno
        umask(oldMask)
        guard bindResult == 0 else { throw POSIXFailure(call: "bind", code: bindErrno) }
        chmod(socketPath, 0o600)

        guard Darwin.listen(fd, 16) == 0 else { throw POSIXFailure(call: "listen", code: errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPending(fd)
        }
        // The descriptor must stay open until the source is fully cancelled.
        source.setCancelHandler {
            close(fd)
        }
        acceptSource = source
        source.resume()
    }

    private func closeListener() {
        guard listenFD >= 0 else { return }
        if let source = acceptSource {
            acceptSource = nil
            source.cancel()  // closes listenFD
        } else {
            close(listenFD)
        }
        listenFD = -1
        unlink(socketPath)
    }

    private func acceptPending(_ fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 {
                if errno != EWOULDBLOCK && errno != EAGAIN && errno != EINTR {
                    os_log("CLI secrets: accept failed: %{public}d", log: logger, type: .error, errno)
                }
                return
            }
            connectionQueue.async { [self] in
                handle(connection: conn)
                close(conn)
            }
        }
    }

    // MARK: - Requests

    private func handle(connection fd: Int32) {
        // Accepted sockets inherit O_NONBLOCK from the listener; requests are
        // small, so use blocking I/O with timeouts instead.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: Self.ioTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0 else {
            os_log("CLI secrets: getpeereid failed: %{public}d", log: logger, type: .error, errno)
            return
        }
        guard peerUID == getuid() || peerUID == 0 else {
            os_log("CLI secrets: refused uid %{public}d", log: logger, type: .error, peerUID)
            respond(fd, .error, Data("permission denied".utf8))
            return
        }

        guard let userId = readUserId(fd) else {
            os_log("CLI secrets: invalid request", log: logger, type: .error)
            respond(fd, .error, Data("invalid request".utf8))
            return
        }

        let sessionToken = secretManager.getSessionToken(userId: userId)
        let olmId = secretManager.getOlmId(userId: userId)
        let olmSecret = secretManager.getOlmSecret(userId: userId)

        if sessionToken.isNilOrEmpty && olmId.isNilOrEmpty && olmSecret.isNilOrEmpty {
            respond(fd, .notFound, Data("{}".utf8))
            return
        }

        let secrets = Secrets(
            sessionToken: sessionToken.nilIfEmpty,
            olmId: olmId.nilIfEmpty,
            olmSecret: olmSecret.nilIfEmpty)
        guard let payload = try? JSONEncoder().encode(secrets) else {
            respond(fd, .error, Data("failed to encode secrets".utf8))
            return
        }
        respond(fd, .ok, payload)
    }

    private func readUserId(_ fd: Int32) -> String? {
        guard let lengthBytes = readExactly(fd, count: 4) else { return nil }
        let length = lengthBytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length > 0, length <= Self.maxUserIdLength else { return nil }
        guard let idBytes = readExactly(fd, count: Int(length)) else { return nil }
        return String(data: idBytes, encoding: .utf8)
    }

    private func respond(_ fd: Int32, _ status: Status, _ payload: Data) {
        var message = Data()
        withUnsafeBytes(of: status.rawValue.littleEndian) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { message.append(contentsOf: $0) }
        message.append(payload)
        writeAll(fd, message)
    }

    private func readExactly(_ fd: Int32, count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { buf in
                read(fd, buf.baseAddress! + offset, count - offset)
            }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return nil }
            offset += n
        }
        return Data(buffer)
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return }
                offset += n
            }
        }
    }
}

nonisolated private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
    var nilIfEmpty: String? { isNilOrEmpty ? nil : self }
}
#endif
