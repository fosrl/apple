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
import os.log

@MainActor
class AuthManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var currentOrg: Organization?
    @Published var organizations: [Organization] = []
    @Published var isLoading = false
    @Published var isInitializing = true
    @Published var errorMessage: String?
    @Published var deviceAuthCode: String?
    @Published var deviceAuthLoginURL: String?
    
    let apiClient: APIClient
    private let configManager: ConfigManager
    private let secretManager: SecretManager
    weak var tunnelManager: TunnelManager?
    
    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return OSLog(subsystem: subsystem, category: "AuthManager")
    }()
    
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
            
            // Always fetch the latest user info to verify the user exists and update stored info
            do {
                let user = try await apiClient.getUser()
                // Update stored config with latest user info
                await handleSuccessfulAuth(user: user, token: token)
            } catch {
                // Token is invalid or user doesn't exist, clear it
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
            organizations = orgsResponse.orgs
            
            // Restore last selected org from config, or auto-select if only one org
            if let savedOrgId = config.orgId,
               let savedOrg = organizations.first(where: { $0.orgId == savedOrgId }) {
                // Restore last selected org
                currentOrg = savedOrg
            } else if orgsResponse.orgs.count == 1 {
                // Auto-select single org
                currentOrg = orgsResponse.orgs.first
                config.orgId = currentOrg?.orgId
                _ = configManager.save(config)
            } else if orgsResponse.orgs.count > 1 {
                // Select first org if no saved org
                currentOrg = orgsResponse.orgs.first
                config.orgId = currentOrg?.orgId
                _ = configManager.save(config)
            }
        } catch {
            // Non-fatal error, continue without org
            os_log("Failed to load organizations: %{public}@", log: logger, type: .error, error.localizedDescription)
            organizations = []
        }
        
        // Ensure OLM credentials exist for this device-account combo
        await ensureOlmCredentials(userId: user.userId)
        
        isAuthenticated = true
        errorMessage = nil
    }
    
    func refreshOrganizations() async {
        // Only refresh if authenticated and user ID is available
        guard isAuthenticated, let userId = currentUser?.userId else {
            return
        }
        
        do {
            let orgsResponse = try await apiClient.listUserOrgs(userId: userId)
            let newOrgs = orgsResponse.orgs
            
            // Preserve current org selection if it still exists in the new list
            let currentOrgId = currentOrg?.orgId
            if let currentOrgId = currentOrgId,
               let updatedOrg = newOrgs.first(where: { $0.orgId == currentOrgId }) {
                // Current org still exists, update it to get latest info
                currentOrg = updatedOrg
            } else if currentOrgId != nil {
                // Current org no longer exists, clear selection
                currentOrg = nil
                var config = configManager.config ?? Config()
                config.orgId = nil
                _ = configManager.save(config)
            }
            
            // Update organizations list
            organizations = newOrgs
            
            os_log("Organizations refreshed successfully: %d orgs", log: logger, type: .debug, newOrgs.count)
        } catch {
            // Fail gracefully - log error but don't disrupt the UI
            os_log("Failed to refresh organizations in background: %{public}@", log: logger, type: .error, error.localizedDescription)
        }
    }
    
    func checkOrgAccess(orgId: String) async -> Bool {
        // First, try to fetch the org to check access
        do {
            _ = try await apiClient.getOrg(orgId: orgId)
            return true
        } catch let error as APIError {
            // Check if it's an unauthorized error (401 or 403)
            if case .httpError(let statusCode, _) = error,
               statusCode == 401 || statusCode == 403 {
                
                // Try to get org policy to understand why access was denied
                if let userId = currentUser?.userId {
                    do {
                        let policyResponse = try await apiClient.checkOrgUserAccess(orgId: orgId, userId: userId)
                        
                        // Log the policy details
                        var policyDetails: [String] = []
                        if let policies = policyResponse.policies {
                            if let requiredTwoFactor = policies.requiredTwoFactor {
                                policyDetails.append("requiredTwoFactor: \(requiredTwoFactor)")
                            }
                            if let maxSessionLength = policies.maxSessionLength {
                                policyDetails.append("maxSessionLength: compliant=\(maxSessionLength.compliant), maxHours=\(maxSessionLength.maxSessionLengthHours), currentHours=\(maxSessionLength.sessionAgeHours)")
                            }
                            if let passwordAge = policies.passwordAge {
                                policyDetails.append("passwordAge: compliant=\(passwordAge.compliant), maxDays=\(passwordAge.maxPasswordAgeDays), currentDays=\(passwordAge.passwordAgeDays)")
                            }
                        }
                        
                        let policyLogMessage = policyDetails.isEmpty ? "none" : policyDetails.joined(separator: ", ")
                        os_log("Org policy check for org %{public}@: allowed=%{public}@, error=%{public}@, policies=[%{public}@]", 
                               log: logger, 
                               type: .error,
                               orgId,
                               String(policyResponse.allowed),
                               policyResponse.error ?? "none",
                               policyLogMessage)
                        
                        // Show alert about org policy preventing access
                        await MainActor.run {
                            AlertManager.shared.showAlertDialog(
                                title: "Access Denied",
                                message: "Org policy preventing access to this org"
                            )
                        }
                        return false
                    } catch {
                        // Failed to get org policy - show generic unauthorized message
                        os_log("Failed to get org policy for org %{public}@: %{public}@", 
                               log: logger, 
                               type: .error,
                               orgId,
                               error.localizedDescription)
                        
                        await MainActor.run {
                            AlertManager.shared.showAlertDialog(
                                title: "Access Denied",
                                message: "Unauthorized access to this org. Contact your admin."
                            )
                        }
                        return false
                    }
                } else {
                    // No user ID available - show generic unauthorized message
                    await MainActor.run {
                        AlertManager.shared.showAlertDialog(
                            title: "Access Denied",
                            message: "Unauthorized access to this org. Contact your admin."
                        )
                    }
                    return false
                }
            } else {
                // Some other error occurred - show it
                await MainActor.run {
                    AlertManager.shared.showErrorDialog(error)
                }
                return false
            }
        } catch {
            // Unexpected error - show it
            await MainActor.run {
                AlertManager.shared.showErrorDialog(error)
            }
            return false
        }
    }
    
    func selectOrganization(_ org: Organization) async {
        // First check org access
        guard await checkOrgAccess(orgId: org.orgId) else {
            return
        }
        
        // If access is granted, proceed with selecting the org
        currentOrg = org
        
        // Save selected org to config
        var config = configManager.config ?? Config()
        config.orgId = org.orgId
        _ = configManager.save(config)
        
        // Switch org in tunnel if connected
        if let tunnelManager = tunnelManager {
            await tunnelManager.switchOrg(orgId: org.orgId)
        }
    }
    
    func ensureOlmCredentials(userId: String) async {
        // Check if OLM credentials already exist locally
        if secretManager.hasOlmCredentials(userId: userId) {
            // Verify OLM exists on server by getting the client
            if let olmIdString = secretManager.getOlmId(userId: userId),
               let clientId = Int(olmIdString) {
                do {
                    let client = try await apiClient.getClient(clientId: clientId)
                    
                    // Verify the olmId matches
                    if let clientOlmId = client.olmId, clientOlmId == olmIdString {
                        os_log("OLM credentials verified successfully", log: logger, type: .debug)
                    } else {
                        os_log("OLM ID mismatch - client olmId: %{public}@, stored olmId: %{public}@", log: logger, type: .error, client.olmId ?? "nil", olmIdString)
                        // Clear invalid credentials
                        _ = secretManager.deleteOlmCredentials(userId: userId)
                    }
                } catch {
                    // If getting client fails, the OLM might not exist
                    os_log("Failed to verify OLM credentials: %{public}@", log: logger, type: .error, error.localizedDescription)
                    // Clear invalid credentials so we can try to create new ones
                    _ = secretManager.deleteOlmCredentials(userId: userId)
                }
            } else {
                // Can't convert olmId to Int, clear credentials
                os_log("Cannot verify OLM - olmId is not a valid clientId", log: logger, type: .error)
                _ = secretManager.deleteOlmCredentials(userId: userId)
            }
        }
        
        // If credentials don't exist or were cleared, create new ones
        if !secretManager.hasOlmCredentials(userId: userId) {
            do {
                let deviceName = DeviceInfo.getDeviceModelName()
                let olmResponse = try await apiClient.createOlm(userId: userId, name: deviceName)
                
                // Save OLM credentials
                let saved = secretManager.saveOlmCredentials(
                    userId: userId,
                    olmId: olmResponse.olmId,
                    secret: olmResponse.secret
                )
                
                if !saved {
                    await MainActor.run {
                        AlertManager.shared.showErrorDialog(
                            NSError(domain: "Pangolin", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to save OLM credentials"])
                        )
                    }
                }
            } catch {
                // Show error alert to user
                await MainActor.run {
                    AlertManager.shared.showErrorDialog(error)
                }
            }
        }
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
        apiClient.updateSessionToken(nil)
        
        isAuthenticated = false
        currentOrg = nil
        organizations = []
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

