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
    @Published var isInitializing = true
    @Published var errorMessage: String?
    @Published var deviceAuthCode: String?
    @Published var deviceAuthLoginURL: String?
    
    let apiClient: APIClient
    private let configManager: ConfigManager
    private let secretManager: SecretManager
    weak var tunnelManager: TunnelManager?
    
    private var deviceAuthTask: Task<Void, Error>?
    
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
        errorMessage = nil
        
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
    
    func loginWithDeviceAuth(hostnameOverride: String? = nil) async throws {
        errorMessage = nil
        
        // Cancel any existing device auth task
        deviceAuthTask?.cancel()
        
        // Create the main login task that can be cancelled
        deviceAuthTask = Task {
            do {
                // Get device name
                let deviceName = ProcessInfo.processInfo.hostName
                
                // Use override hostname if provided, otherwise use current baseURL
                let hostname = hostnameOverride ?? apiClient.currentBaseURL
                
                // Start device auth
                let startResponse = try await apiClient.startDeviceAuth(
                    applicationName: "Pangolin macOS Client",
                    deviceName: deviceName,
                    hostnameOverride: hostnameOverride
                )
                
                // Store code and URL for UI display
                let code = startResponse.code
                let loginURL = "\(hostname)/auth/login/device"
                
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
                    // Check for cancellation
                    try Task.checkCancellation()
                    
                    try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                    
                    // Check for cancellation again after sleep
                    try Task.checkCancellation()
                    
                    let (pollResponse, token) = try await apiClient.pollDeviceAuth(code: code, hostnameOverride: hostnameOverride)
                    
                    if pollResponse.verified {
                        verified = true
                        sessionToken = token
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
                
                // Update hostname in config and API client if override was provided
                if let hostname = hostnameOverride {
                    var config = configManager.config ?? Config()
                    config.hostname = hostname
                    _ = configManager.save(config)
                    apiClient.updateBaseURL(hostname)
                }
                
                // Get user info
                let user = try await apiClient.getUser()
                await handleSuccessfulAuth(user: user, token: token)
                
                // Clear device auth UI state after successful auth
                await MainActor.run {
                    self.deviceAuthCode = nil
                    self.deviceAuthLoginURL = nil
                    self.deviceAuthTask = nil
                }
            } catch let error as APIError {
                await MainActor.run {
                    self.deviceAuthCode = nil
                    self.deviceAuthLoginURL = nil
                    self.deviceAuthTask = nil
                }
                errorMessage = error.errorDescription
                throw error
            } catch is CancellationError {
                await MainActor.run {
                    self.deviceAuthCode = nil
                    self.deviceAuthLoginURL = nil
                    self.deviceAuthTask = nil
                }
                throw CancellationError()
            } catch {
                await MainActor.run {
                    self.deviceAuthCode = nil
                    self.deviceAuthLoginURL = nil
                    self.deviceAuthTask = nil
                }
                errorMessage = error.localizedDescription
                throw error
            }
        }
        
        // Wait for the task to complete and re-throw any errors
        try await deviceAuthTask?.value
    }
    
    func cancelDeviceAuth() {
        deviceAuthTask?.cancel()
        deviceAuthTask = nil
        deviceAuthCode = nil
        deviceAuthLoginURL = nil
        errorMessage = nil
    }
    
    private func handleSuccessfulAuth(user: User, token: String) async {
        // Disconnect tunnel on successful login to ensure clean state
        if let tunnelManager = tunnelManager {
            await tunnelManager.disconnect()
        }
        
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
                        // Get hostname for the resolution URL
                        let hostname = configManager.getHostname()
                        let resolutionURL = "\(hostname)/\(orgId)"
                        
                        // Build message similar to Go implementation
                        var message = "Access denied due to organization policy violations."
                        if let error = policyResponse.error, !error.isEmpty {
                            message = "Access denied: \(error)"
                        }
                        message += "\n\nSee more and resolve the issues by visiting: \(resolutionURL)"
                        
                        await MainActor.run {
                            AlertManager.shared.showAlertDialog(
                                title: "Access Denied",
                                message: message
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
            // Verify OLM exists on server by getting the OLM directly
            if let olmIdString = secretManager.getOlmId(userId: userId) {
                do {
                    let olm = try await apiClient.getUserOlm(userId: userId, olmId: olmIdString)
                    
                    // Verify the olmId and userId match
                    if olm.olmId == olmIdString && olm.userId == userId {
                        os_log("OLM credentials verified successfully", log: logger, type: .debug)
                    } else {
                        os_log("OLM mismatch - returned olmId: %{public}@, userId: %{public}@, stored olmId: %{public}@", log: logger, type: .error, olm.olmId, olm.userId, olmIdString)
                        // Clear invalid credentials
                        _ = secretManager.deleteOlmCredentials(userId: userId)
                    }
                } catch {
                    // If getting OLM fails, the OLM might not exist
                    os_log("Failed to verify OLM credentials: %{public}@", log: logger, type: .error, error.localizedDescription)
                    // Clear invalid credentials so we can try to create new ones
                    _ = secretManager.deleteOlmCredentials(userId: userId)
                }
            } else {
                // No olmId found, clear credentials
                os_log("Cannot verify OLM - olmId not found", log: logger, type: .error)
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
        // Disconnect tunnel before logging out
        if let tunnelManager = tunnelManager {
            await tunnelManager.disconnect()
        }
        
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

