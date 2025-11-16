//
//  AuthManager.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import Foundation
import AppKit
import Combine
import UserNotifications

@MainActor
class AuthManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var currentOrg: Organization?
    @Published var isLoading = false
    @Published var isInitializing = true
    @Published var errorMessage: String?
    @Published var deviceAuthCode: String?
    @Published var deviceAuthLoginURL: String?
    
    let apiClient: APIClient
    private let configManager: ConfigManager
    private let secretManager: SecretManager
    
    init(apiClient: APIClient, configManager: ConfigManager, secretManager: SecretManager) {
        self.apiClient = apiClient
        self.configManager = configManager
        self.secretManager = secretManager
    }
    
    func initialize() async {
        isInitializing = true
        defer { isInitializing = false }
        
        // Load session token from Keychain
        if let token = secretManager.getSecret(key: "session-token") {
            apiClient.updateSessionToken(token)
            
            // Verify token is still valid
            do {
                let user = try await apiClient.getUser()
                await handleSuccessfulAuth(user: user, token: token)
            } catch {
                // Token is invalid, clear it
                _ = secretManager.deleteSecret(key: "session-token")
                _ = configManager.clear()
                isAuthenticated = false
            }
        } else {
            isAuthenticated = false
        }
    }
    
    func loginWithCredentials(email: String, password: String, code: String?) async throws {
        isLoading = true
        errorMessage = nil
        
        defer { isLoading = false }
        
        do {
            let (loginResponse, token) = try await apiClient.login(email: email, password: password, code: code)
            
            // Check if 2FA code is required
            if loginResponse.codeRequested == true {
                throw AuthError.twoFactorRequired
            }
            
            if loginResponse.emailVerificationRequired == true {
                throw AuthError.emailVerificationRequired
            }
            
            // Save token
            _ = secretManager.saveSecret(key: "session-token", value: token)
            apiClient.updateSessionToken(token)
            
            // Get user info
            let user = try await apiClient.getUser()
            await handleSuccessfulAuth(user: user, token: token)
            
        } catch let error as APIError {
            errorMessage = error.errorDescription
            throw error
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
    
    func loginWithDeviceAuth() async throws {
        isLoading = true
        errorMessage = nil
        
        defer { isLoading = false }
        
        do {
            // Get device name
            let deviceName = ProcessInfo.processInfo.hostName
            
            // Start device auth
            let startResponse = try await apiClient.startDeviceAuth(
                applicationName: "Pangolin Menu Bar",
                deviceName: deviceName
            )
            
            // Store code and URL for UI display
            let code = startResponse.code
            let loginURL = "\(apiClient.currentBaseURL)/auth/login/device"
            
            await MainActor.run {
                self.deviceAuthCode = code
                self.deviceAuthLoginURL = loginURL
            }
            
            // Show notification with code
            let content = UNMutableNotificationContent()
            content.title = "Pangolin Login"
            content.body = "Enter code: \(code)"
            content.sound = .default
            
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try await UNUserNotificationCenter.current().add(request)
            
            // Poll for verification
            let expiresAt = Date(timeIntervalSince1970: TimeInterval(startResponse.expiresAt / 1000))
            var verified = false
            var sessionToken: String?
            
            while !verified && Date() < expiresAt {
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                
                let (pollResponse, token) = try await apiClient.pollDeviceAuth(code: code)
                
                if pollResponse.verified {
                    verified = true
                    if let token = token {
                        sessionToken = token
                    }
                } else if let message = pollResponse.message,
                          (message.contains("expired") || message.contains("not found")) {
                    await MainActor.run {
                        self.deviceAuthCode = nil
                        self.deviceAuthLoginURL = nil
                    }
                    throw AuthError.deviceCodeExpired
                }
            }
            
            if !verified {
                await MainActor.run {
                    self.deviceAuthCode = nil
                    self.deviceAuthLoginURL = nil
                }
                throw AuthError.deviceCodeExpired
            }
            
            guard let token = sessionToken else {
                throw AuthError.invalidToken
            }
            
            // Save token
            _ = secretManager.saveSecret(key: "session-token", value: token)
            apiClient.updateSessionToken(token)
            
            // Get user info
            let user = try await apiClient.getUser()
            await handleSuccessfulAuth(user: user, token: token)
            
            // Clear device auth UI state after successful auth
            await MainActor.run {
                self.deviceAuthCode = nil
                self.deviceAuthLoginURL = nil
            }
            
        } catch let error as APIError {
            errorMessage = error.errorDescription
            throw error
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
    
    private func handleSuccessfulAuth(user: User, token: String) async {
        // Save user info to config
        var config = configManager.config ?? Config()
        config.userId = user.userId
        config.email = user.email
        config.username = user.username
        config.name = user.name
        _ = configManager.save(config)
        
        currentUser = user
        
        // Get organizations
        do {
            let orgsResponse = try await apiClient.listUserOrgs(userId: user.userId)
            
            if orgsResponse.orgs.count == 1 {
                // Auto-select single org
                currentOrg = orgsResponse.orgs.first
                config.orgId = currentOrg?.orgId
                _ = configManager.save(config)
            } else if orgsResponse.orgs.count > 1 {
                // For now, select first org (can be enhanced later)
                currentOrg = orgsResponse.orgs.first
                config.orgId = currentOrg?.orgId
                _ = configManager.save(config)
            }
        } catch {
            // Non-fatal error, continue without org
            print("Failed to load organizations: \(error)")
        }
        
        isAuthenticated = true
        errorMessage = nil
    }
    
    func logout() async {
        isLoading = true
        defer { isLoading = false }
        
        // Try to call logout endpoint (ignore errors)
        do {
            try await apiClient.logout()
        } catch {
            // Ignore errors - still clear local data
        }
        
        // Clear local data
        _ = secretManager.deleteSecret(key: "session-token")
        _ = configManager.clear()
        apiClient.updateSessionToken(nil)
        
        isAuthenticated = false
        currentUser = nil
        currentOrg = nil
        errorMessage = nil
        deviceAuthCode = nil
        deviceAuthLoginURL = nil
    }
}

enum AuthError: Error, LocalizedError {
    case twoFactorRequired
    case emailVerificationRequired
    case deviceCodeExpired
    case invalidToken
    
    var errorDescription: String? {
        switch self {
        case .twoFactorRequired:
            return "Two-factor authentication code required"
        case .emailVerificationRequired:
            return "Email verification required"
        case .deviceCodeExpired:
            return "Device code expired. Please try again."
        case .invalidToken:
            return "Invalid session token"
        }
    }
}

