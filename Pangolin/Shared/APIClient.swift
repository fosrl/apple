//
//  APIClient.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import Foundation
import Combine
import os.log

enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String?)
    case networkError(Error)
    case decodingError(Error)
    case blocked
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let status, let message):
            if let message = message, !message.isEmpty {
                return message
            }
            switch status {
            case 401, 403:
                return "Unauthorized"
            case 404:
                return "Not found"
            case 429:
                return "Rate limit exceeded"
            case 500:
                return "Internal server error"
            default:
                return "HTTP error \(status)"
            }
        case .networkError(let error):
            return error.localizedDescription
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .blocked:
            return "Your device is blocked in this organization. Contact your admin for more information."
        }
    }
}

class APIClient: ObservableObject {
    private var baseURL: String
    private var sessionToken: String?
    private let sessionCookieName = "p_session_token"
    private let csrfToken = "x-csrf-protection"
    
    private var agentName: String {
        #if os(iOS)
        let platform = "iOS"
        #elseif os(macOS)
        let platform = "macOS"
        #else
        let platform = "Unknown"
        #endif
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        return "pangolin-\(platform)-\(version)"
    }
    
    private let session: URLSession
    
    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return OSLog(subsystem: subsystem, category: "APIClient")
    }()
    
    var currentBaseURL: String {
        return baseURL
    }
    
    init(baseURL: String, sessionToken: String?) {
        self.baseURL = Self.normalizeBaseURL(baseURL)
        self.sessionToken = sessionToken
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        self.session = URLSession(configuration: configuration)
                
        os_log("APIClient initialized with baseURL: %{public}@", log: logger, type: .info, self.baseURL)
    }
    
    func updateBaseURL(_ newBaseURL: String) {
        self.baseURL = Self.normalizeBaseURL(newBaseURL)
    }
    
    func updateSessionToken(_ token: String?) {
        self.sessionToken = token
    }
    
    private static func normalizeBaseURL(_ url: String) -> String {
        var normalized = url.trimmingCharacters(in: .whitespaces)
        
        // If empty, return default
        if normalized.isEmpty {
            return "https://app.pangolin.net"
        }
        
        if !normalized.hasPrefix("http://") && !normalized.hasPrefix("https://") {
            normalized = "https://" + normalized
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized
    }
    
    private func apiURL(_ path: String, hostnameOverride: String? = nil, queryParams: [String: String]? = nil) -> URL? {
        let fullPath = path.hasPrefix("/") ? path : "/\(path)"
        let apiPath = "/api/v1\(fullPath)"
        let hostname = hostnameOverride ?? baseURL
        let normalizedHostname = Self.normalizeBaseURL(hostname)
        var fullURL = normalizedHostname + apiPath
        
        // Add query parameters if provided
        if let queryParams = queryParams, !queryParams.isEmpty {
            var queryItems: [String] = []
            for (key, value) in queryParams {
                if let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                    queryItems.append("\(encodedKey)=\(encodedValue)")
                }
            }
            if !queryItems.isEmpty {
                fullURL += "?" + queryItems.joined(separator: "&")
            }
        }
        
        // Validate URL construction
        guard let url = URL(string: fullURL) else {
            os_log("Error: Invalid URL constructed: %{public}@ (hostname: %{public}@, path: %{public}@)", log: logger, type: .error, fullURL, normalizedHostname, path)
            return nil
        }
        
        return url
    }
    
    private func makeRequest(
        method: String,
        path: String,
        body: Data? = nil,
        hostnameOverride: String? = nil,
        queryParams: [String: String]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = apiURL(path, hostnameOverride: hostnameOverride, queryParams: queryParams) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(agentName, forHTTPHeaderField: "User-Agent")
        request.setValue(csrfToken, forHTTPHeaderField: "X-CSRF-Token")
        
        // Add session cookie if available
        if let token = sessionToken {
            request.setValue("\(sessionCookieName)=\(token)", forHTTPHeaderField: "Cookie")
        }
        
        if let body = body {
            request.httpBody = body
        }
        
        do {
            os_log("Making request to: %{public}@", log: logger, type: .debug, url.absoluteString)
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            return (data, httpResponse)
        } catch let error as URLError {
            // Log detailed error information
            os_log("URLError: %{public}@", log: logger, type: .error, error.localizedDescription)
            os_log("Error code: %d", log: logger, type: .error, error.code.rawValue)
            os_log("Error domain: %{public}@", log: logger, type: .error, error._domain)
            if let url = error.failingURL {
                os_log("Failed URL: %{public}@", log: logger, type: .error, url.absoluteString)
            }
            
            // Provide more specific error messages
            switch error.code {
            case .cannotFindHost:
                let message = "Cannot find server at \(baseURL). Error: \(error.localizedDescription). Please verify the server URL is correct and accessible."
                os_log("%{public}@", log: logger, type: .error, message)
                throw APIError.httpError(0, message)
            case .cannotConnectToHost:
                let message = "Cannot connect to server at \(baseURL). Error: \(error.localizedDescription). Please check if the server is running and accessible."
                os_log("%{public}@", log: logger, type: .error, message)
                throw APIError.httpError(0, message)
            case .timedOut:
                let message = "Connection to \(baseURL) timed out. Please check your network connection."
                os_log("%{public}@", log: logger, type: .error, message)
                throw APIError.httpError(0, message)
            case .dnsLookupFailed:
                let message = "DNS lookup failed for \(baseURL). Error: \(error.localizedDescription). Please check if the hostname is correct."
                os_log("%{public}@", log: logger, type: .error, message)
                throw APIError.httpError(0, message)
            default:
                let message = "Network error: \(error.localizedDescription) (code: \(error.code.rawValue))"
                os_log("%{public}@", log: logger, type: .error, message)
                throw APIError.networkError(error)
            }
        } catch {
            os_log("Unexpected error: %{public}@", log: logger, type: .error, error.localizedDescription)
            throw APIError.networkError(error)
        }
    }
    
    private func parseResponse<T: Codable>(_ data: Data, _ response: HTTPURLResponse) throws -> T {
        // Check HTTP status first
        guard (200...299).contains(response.statusCode) else {
            // Try to parse error message from response
            var errorMessage: String? = nil
            if let errorResponse = try? JSONDecoder().decode(APIResponse<EmptyResponse>.self, from: data) {
                errorMessage = errorResponse.message
            }
            throw APIError.httpError(response.statusCode, errorMessage)
        }
        
        // Handle empty responses (e.g., logout)
        if data.isEmpty || (data.count == 2 && String(data: data, encoding: .utf8) == "{}") {
            // Try to create an instance of T if it's EmptyResponse
            if T.self == EmptyResponse.self {
                return EmptyResponse() as! T
            }
            throw APIError.invalidResponse
        }
        
        // Parse API response wrapper
        let apiResponse = try JSONDecoder().decode(APIResponse<T>.self, from: data)
        
        // Check API-level success/error flags
        if let success = apiResponse.success, !success {
            let message = apiResponse.message ?? "Request failed"
            let status = apiResponse.status ?? response.statusCode
            throw APIError.httpError(status, message)
        }
        
        if let error = apiResponse.error, error == true {
            let message = apiResponse.message ?? "Request failed"
            let status = apiResponse.status ?? response.statusCode
            throw APIError.httpError(status, message)
        }
        
        // For logout and other endpoints that might return empty data, allow nil data
        if let data = apiResponse.data {
            return data
        } else {
            // If data is nil but response was successful, try to return EmptyResponse
            if T.self == EmptyResponse.self {
                return EmptyResponse() as! T
            }
            throw APIError.invalidResponse
        }
    }
    
    private func extractCookie(from response: HTTPURLResponse, name: String) -> String? {
        guard let headers = response.allHeaderFields as? [String: String] else {
            return nil
        }
        
        // Check Set-Cookie header
        if let setCookie = headers["Set-Cookie"] {
            // Parse cookie string (format: "name=value; Path=/; ...")
            let components = setCookie.components(separatedBy: ";")
            for component in components {
                let parts = component.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
                if parts.count == 2, parts[0] == name {
                    return parts[1]
                }
            }
        }
        
        // Also check for multiple Set-Cookie headers (less common)
        for (key, value) in headers {
            if key.lowercased() == "set-cookie" {
                let components = value.components(separatedBy: ";")
                for component in components {
                    let parts = component.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
                    if parts.count == 2, parts[0] == name {
                        return parts[1]
                    }
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Authentication
    
    func login(email: String, password: String, code: String?) async throws -> (LoginResponse, String) {
        let requestBody = LoginRequest(email: email, password: password, code: code)
        let bodyData = try JSONEncoder().encode(requestBody)
        
        let (data, response) = try await makeRequest(method: "POST", path: "/auth/login", body: bodyData)
        
        let loginResponse: LoginResponse = try parseResponse(data, response)
        
        // Extract session token from cookie
        var sessionToken: String? = nil
        
        // Try both cookie names
        sessionToken = extractCookie(from: response, name: sessionCookieName)
        if sessionToken == nil {
            sessionToken = extractCookie(from: response, name: "p_session")
        }
        
        guard let token = sessionToken else {
            throw APIError.invalidResponse
        }
        
        return (loginResponse, token)
    }
    
    func startDeviceAuth(applicationName: String, deviceName: String?, hostnameOverride: String? = nil) async throws -> DeviceAuthStartResponse {
        let requestBody = DeviceAuthStartRequest(applicationName: applicationName, deviceName: deviceName)
        let bodyData = try JSONEncoder().encode(requestBody)
        
        let (data, response) = try await makeRequest(method: "POST", path: "/auth/device-web-auth/start", body: bodyData, hostnameOverride: hostnameOverride)
        
        return try parseResponse(data, response)
    }
    
    func pollDeviceAuth(code: String, hostnameOverride: String? = nil) async throws -> (DeviceAuthPollResponse, String?) {
        let (data, response) = try await makeRequest(method: "GET", path: "/auth/device-web-auth/poll/\(code)", hostnameOverride: hostnameOverride)
        
        let pollResponse: DeviceAuthPollResponse = try parseResponse(data, response)
        
        // Extract token if verified
        var sessionToken: String? = nil
        if pollResponse.verified, let token = pollResponse.token {
            sessionToken = token
        } else {
            // Also try to extract from cookie
            sessionToken = extractCookie(from: response, name: sessionCookieName)
            if sessionToken == nil {
                sessionToken = extractCookie(from: response, name: "p_session")
            }
        }
        
        return (pollResponse, sessionToken)
    }
    
    func logout() async throws {
        let (data, response) = try await makeRequest(method: "POST", path: "/auth/logout", body: Data())
        _ = try parseResponse(data, response) as EmptyResponse
    }
    
    // MARK: - User
    
    func getUser() async throws -> User {
        let (data, response) = try await makeRequest(method: "GET", path: "/user")
        return try parseResponse(data, response)
    }
    
    func listUserOrgs(userId: String) async throws -> ListUserOrgsResponse {
        let (data, response) = try await makeRequest(method: "GET", path: "/user/\(userId)/orgs")
        return try parseResponse(data, response)
    }
    
    func createOlm(userId: String, name: String) async throws -> CreateOlmResponse {
        let requestBody = CreateOlmRequest(name: name)
        let bodyData = try JSONEncoder().encode(requestBody)
        
        let (data, response) = try await makeRequest(method: "PUT", path: "/user/\(userId)/olm", body: bodyData)
        return try parseResponse(data, response)
    }
    
    func getUserOlm(userId: String, olmId: String, orgId: String? = nil) async throws -> Olm {
        var queryParams: [String: String]? = nil
        if let orgId = orgId {
            queryParams = ["orgId": orgId]
        }
        let (data, response) = try await makeRequest(method: "GET", path: "/user/\(userId)/olm/\(olmId)", queryParams: queryParams)
        return try parseResponse(data, response)
    }

    func recoverOlmWithFingerprint(userId: String, platformFingerprint: String) async throws -> RecoverOlmResponse {
        let requestBody = RecoverOlmRequest(platformFingerprint: platformFingerprint)
        let bodyData = try JSONEncoder().encode(requestBody);

        let (data, response) = try await makeRequest(method: "POST", path: "/user/\(userId)/olm/recover", body: bodyData)
        return try parseResponse(data, response)
    }
    
    // MARK: - Organization
    
    func getOrg(orgId: String) async throws -> GetOrgResponse {
        let (data, response) = try await makeRequest(method: "GET", path: "/org/\(orgId)")
        return try parseResponse(data, response)
    }
    
    func checkOrgUserAccess(orgId: String, userId: String) async throws -> CheckOrgUserAccessResponse {
        let (data, response) = try await makeRequest(method: "GET", path: "/org/\(orgId)/user/\(userId)/check")
        return try parseResponse(data, response)
    }
    
    // MARK: - Client
    
    func getClient(clientId: Int) async throws -> GetClientResponse {
        let (data, response) = try await makeRequest(method: "GET", path: "/client/\(clientId)")
        return try parseResponse(data, response)
    }
    
    // MARK: - Connection Test
    
    func testConnection() async throws -> Bool {
        guard let url = URL(string: baseURL) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(agentName, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        
        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 404
        } catch {
            return false
        }
    }
}

// Helper type for empty responses
struct EmptyResponse: Codable {}

