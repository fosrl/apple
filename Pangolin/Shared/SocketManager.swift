import Darwin
import Foundation
import os.log

enum SocketError: Error, LocalizedError {
    case socketDoesNotExist
    case connectionFailed(Error)
    case invalidResponse
    case httpError(Int, String?)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .socketDoesNotExist:
            return "Socket does not exist (is the tunnel running?)"
        case .connectionFailed(let error):
            return "Failed to connect to socket: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let status, let message):
            if let message = message, !message.isEmpty {
                return message
            }
            return "HTTP error \(status)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        }
    }
}

class SocketManager {
    private let socketPath: String
    private let timeout: TimeInterval

    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "com.cndf.vpn"
        return OSLog(subsystem: subsystem, category: "SocketManager")
    }()

    init(socketPath: String? = nil, timeout: TimeInterval = 5.0) {
        // Use provided path or get the platform-appropriate default
        self.socketPath = socketPath ?? getSocketPath()
        self.timeout = timeout
    }

    /// Checks if the tunnel process is running by querying the socket status
    /// Returns true if the socket responds successfully, false otherwise
    func isRunning() async -> Bool {
        // First check if socket file exists (quick check)
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return false
        }

        // Actually query the socket to verify it's responding
        do {
            _ = try await getStatus()
            return true
        } catch {
            // Socket exists but doesn't respond - not running
            return false
        }
    }

    /// Retrieves the current status from the tunnel process
    func getStatus() async throws -> SocketStatusResponse {
        return try await performRequest(method: "GET", path: "/status", body: nil)
    }

    /// Sends a shutdown signal to the tunnel process
    func exit() async throws -> SocketExitResponse {
        return try await performRequest(method: "POST", path: "/exit", body: nil)
    }

    /// Switches to a different organization
    func switchOrg(orgId: String) async throws -> SocketSwitchOrgResponse {
        let requestBody = SocketSwitchOrgRequest(orgId: orgId)
        let bodyData = try JSONEncoder().encode(requestBody)
        return try await performRequest(method: "POST", path: "/switch-org", body: bodyData)
    }

    /// Switches to a different organization
    func updateMetadata(fingerprint: Fingerprint, postures: Postures) async throws
        -> UpdateMetadataResponse
    {
        let payload = UpdateMetadataRequest(
            fingerprint: fingerprint,
            postures: postures,
        )

        let bodyData = try JSONEncoder().encode(payload)

        return try await performRequest(method: "PUT", path: "/metadata", body: bodyData)
    }

    // MARK: - Private Methods

    private func performRequest<T: Decodable>(
        method: String,
        path: String,
        body: Data?
    ) async throws -> T {
        // Check if socket exists
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw SocketError.socketDoesNotExist
        }

        // Create HTTP request
        var request = "\(method) \(path) HTTP/1.1\r\n"
        request += "Host: localhost\r\n"
        request += "Connection: close\r\n"

        if let body = body {
            request += "Content-Type: application/json\r\n"
            request += "Content-Length: \(body.count)\r\n"
        }

        request += "\r\n"

        // Convert request to data
        var requestData = request.data(using: .utf8) ?? Data()
        if let body = body {
            requestData.append(body)
        }

        // Connect to Unix socket and send request
        let responseData = try await connectAndSend(requestData: requestData)

        // Parse HTTP response
        let (statusCode, responseBody) = try parseHTTPResponse(responseData)

        // Check status code
        guard statusCode == 200 else {
            let errorMessage = String(data: responseBody, encoding: .utf8)
            throw SocketError.httpError(statusCode, errorMessage)
        }

        // Decode JSON response
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: responseBody)
        } catch {
            os_log(
                "JSON decode error: %{public}@", log: logger, type: .error,
                error.localizedDescription)
            if let bodyString = String(data: responseBody, encoding: .utf8) {
                os_log("Failed to decode body: %{public}@", log: logger, type: .error, bodyString)
            }
            throw SocketError.decodingError(error)
        }
    }

    private func connectAndSend(requestData: Data) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            let socket = socket(AF_UNIX, SOCK_STREAM, 0)
            guard socket >= 0 else {
                continuation.resume(
                    throwing: SocketError.connectionFailed(
                        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
                    ))
                return
            }

            defer {
                close(socket)
            }

            // Set socket address
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let socketPathCString = socketPath.utf8CString
            let pathLength = min(
                socketPathCString.count - 1, MemoryLayout.size(ofValue: addr.sun_path) - 1)

            // Copy path to sun_path using withUnsafeMutableBytes to avoid exclusive access issues
            withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
                let destPtr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self)
                socketPathCString.withUnsafeBufferPointer { sourceBuffer in
                    if let dest = destPtr, let source = sourceBuffer.baseAddress {
                        _ = memcpy(dest, source, pathLength)
                        dest[pathLength] = 0
                    }
                }
            }

            // Calculate address length
            let addrLen = socklen_t(MemoryLayout.size(ofValue: addr.sun_family) + pathLength + 1)

            // Connect to socket
            let connectResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socket, $0, addrLen)
                }
            }

            guard connectResult == 0 else {
                continuation.resume(
                    throwing: SocketError.connectionFailed(
                        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
                    ))
                return
            }

            // Set timeout
            var timeoutValue = timeval()
            timeoutValue.tv_sec = Int(timeout)
            timeoutValue.tv_usec = Int32((timeout - Double(timeoutValue.tv_sec)) * 1_000_000)
            setsockopt(
                socket, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue,
                socklen_t(MemoryLayout.size(ofValue: timeoutValue)))
            setsockopt(
                socket, SOL_SOCKET, SO_SNDTIMEO, &timeoutValue,
                socklen_t(MemoryLayout.size(ofValue: timeoutValue)))

            // Send request
            let sendResult = requestData.withUnsafeBytes { bytes in
                send(socket, bytes.baseAddress, requestData.count, 0)
            }

            guard sendResult >= 0 else {
                continuation.resume(
                    throwing: SocketError.connectionFailed(
                        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
                    ))
                return
            }

            // Receive response
            var responseData = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)

            while true {
                let bytesReceived = recv(socket, &buffer, buffer.count, 0)

                if bytesReceived <= 0 {
                    if bytesReceived == 0 {
                        // Connection closed
                        break
                    } else {
                        // Error
                        if errno == EAGAIN || errno == EWOULDBLOCK {
                            // Timeout
                            break
                        } else {
                            continuation.resume(
                                throwing: SocketError.connectionFailed(
                                    NSError(
                                        domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
                                ))
                            return
                        }
                    }
                } else {
                    responseData.append(buffer, count: bytesReceived)
                }
            }

            continuation.resume(returning: responseData)
        }
    }

    private func parseHTTPResponse(_ data: Data) throws -> (statusCode: Int, body: Data) {
        guard let responseString = String(data: data, encoding: .utf8) else {
            throw SocketError.invalidResponse
        }

        // Try to split by \r\n\r\n first (standard HTTP)
        var components = responseString.components(separatedBy: "\r\n\r\n")

        // If that doesn't work, try \n\n (some servers use just \n)
        if components.count < 2 {
            components = responseString.components(separatedBy: "\n\n")
        }

        guard components.count >= 2 else {
            os_log(
                "Failed to split response into headers and body. Response length: %d", log: logger,
                type: .error, responseString.count)
            os_log(
                "Response preview: %{public}@", log: logger, type: .error,
                String(responseString.prefix(200)))
            throw SocketError.invalidResponse
        }

        let headers = components[0]
        let bodyString = components.dropFirst().joined(
            separator: components.count > 2 ? "\r\n\r\n" : "\n\n")

        // Parse status line (first line of headers)
        let headerLines = headers.components(separatedBy: "\r\n")
        let statusLine = headerLines.first ?? headers.components(separatedBy: "\n").first ?? ""

        // Parse HTTP/1.1 200 OK format
        let statusComponents = statusLine.components(separatedBy: " ")
        guard statusComponents.count >= 2,
            let statusCode = Int(statusComponents[1])
        else {
            os_log("Failed to parse status line: %{public}@", log: logger, type: .error, statusLine)
            throw SocketError.invalidResponse
        }

        // Convert body string back to data
        guard let bodyData = bodyString.data(using: .utf8) else {
            os_log(
                "Failed to convert body string to data. Body: %{public}@", log: logger,
                type: .error, bodyString)
            throw SocketError.invalidResponse
        }

        return (statusCode, bodyData)
    }
}

private struct UpdateMetadataRequest: Codable {
    let fingerprint: Fingerprint
    let postures: Postures
}
