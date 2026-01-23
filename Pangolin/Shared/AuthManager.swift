//
//  AuthManager.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import Combine
import Foundation
import UserNotifications
import os.log

#if os(iOS)
    import UIKit
#endif

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
    @Published var serverInfo: ServerInfo?
    @Published var isServerDown = false

    let apiClient: APIClient
    private let configManager: ConfigManager
    private let accountManager: AccountManager
    private let secretManager: SecretManager
    weak var tunnelManager: TunnelManager?

    private var deviceAuthTask: Task<Void, Error>?

    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return OSLog(subsystem: subsystem, category: "AuthManager")
    }()

    init(
        apiClient: APIClient,
        configManager: ConfigManager,
        accountManager: AccountManager,
        secretManager: SecretManager,
    ) {
        self.apiClient = apiClient
        self.configManager = configManager
        self.accountManager = accountManager
        self.secretManager = secretManager
    }

    func initialize() async {
        isInitializing = true
        defer { isInitializing = false }
        
        isServerDown = false

        if let activeAccount = accountManager.activeAccount,
            let token = secretManager.getSessionToken(userId: activeAccount.userId)
        {
            apiClient.updateSessionToken(token)
            apiClient.updateBaseURL(activeAccount.hostname)

            // Check server health first
            var healthCheckFailed = false
            do {
                let isHealthy = try await apiClient.checkHealth()
                if !isHealthy {
                    healthCheckFailed = true
                }
            } catch {
                // Health check failed, server is likely down
                healthCheckFailed = true
            }
            
            if healthCheckFailed {
                // Server is down, but show last known user info
                isServerDown = true
                // Keep showing the last known user if we have it
                if currentUser == nil {
                    // Try to load user from stored account info
                    // We'll still show as authenticated to display the UI
                    isAuthenticated = true
                } else {
                    // Keep authenticated state to show last known info
                    isAuthenticated = true
                }
                return
            }

            // Always fetch the latest user info to verify the user exists and update stored info
            do {
                let user = try await apiClient.getUser()
                // Update stored account with latest user info
                accountManager.updateAccountUserInfo(userId: activeAccount.userId, username: user.username, name: user.name)
                // Update stored config with latest user info
                await handleSuccessfulAuth(
                    user: user, hostname: activeAccount.hostname, token: token)
            } catch {
                // Token is invalid or user doesn't exist, clear it
                isAuthenticated = false
            }
        } else {
            isAuthenticated = false
        }
    }

    func loginWithDeviceAuth(hostnameOverride: String? = nil) async throws {
        let loginApiClient: APIClient
        if let hostname = hostnameOverride {
            loginApiClient = APIClient(baseURL: hostname, sessionToken: nil)
        } else {
            loginApiClient = apiClient
        }

        errorMessage = nil

        // Cancel any existing device auth task
        deviceAuthTask?.cancel()

        // Create the main login task that can be cancelled
        deviceAuthTask = Task {
            do {
                // Get device name (user's computer/device name)
                let deviceName = DeviceInfo.getDeviceModelName()

                let hostname = loginApiClient.currentBaseURL

                #if os(iOS)
                    let applicationName: String
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        applicationName = "Pangolin iPadOS Client"
                    } else {
                        applicationName = "Pangolin iOS Client"
                    }
                #elseif os(macOS)
                    let applicationName = "Pangolin macOS Client"
                #else
                    let applicationName = "Pangolin Client"
                #endif

                let startResponse = try await loginApiClient.startDeviceAuth(
                    applicationName: applicationName,
                    deviceName: deviceName,
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

                let request = UNNotificationRequest(
                    identifier: UUID().uuidString, content: content, trigger: nil)
                try await UNUserNotificationCenter.current().add(request)

                // Poll for verification
                let expiresAt = Date().addingTimeInterval(
                    TimeInterval(startResponse.expiresInSeconds))
                var verified = false
                var sessionToken: String?

                while !verified && Date() < expiresAt {
                    // Check for cancellation
                    try Task.checkCancellation()

                    try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second

                    // Check for cancellation again after sleep
                    try Task.checkCancellation()

                    let (pollResponse, token) = try await loginApiClient.pollDeviceAuth(
                        code: code, hostnameOverride: hostnameOverride)

                    if pollResponse.verified {
                        verified = true
                        sessionToken = token
                    } else if let message = pollResponse.message,
                        message.contains("expired") || message.contains("not found")
                    {
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

                // Update the current client, and attempt to fetch the current
                // user using that token.
                //
                // If that succeeds, then update the rest of the application's
                // auth state. Otherwise, don't do anything else and just
                // exit the auth process.

                apiClient.updateSessionToken(token)
                apiClient.updateBaseURL(hostname)

                // Get user info
                let user = try await apiClient.getUser()
                await handleSuccessfulAuth(user: user, hostname: hostname, token: token)

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

    private func handleSuccessfulAuth(user: User, hostname: String, token: String) async {
        apiClient.updateSessionToken(token)
        apiClient.updateBaseURL(hostname)

        // Disconnect tunnel on successful login to ensure clean state (macOS only)
        // On iOS, we want to preserve the existing connection state and just reflect it
        #if os(macOS)
            if let tunnelManager = tunnelManager {
                await tunnelManager.disconnect()
            }
        #endif

        currentUser = user

        let selectedOrgId: String
        do {
            selectedOrgId = try await ensureOrgIsSelected()
        } catch {
            os_log(
                "Failed to ensure organization is selected: %{public}@", log: logger, type: .error,
                error.localizedDescription)
            organizations = []
            selectedOrgId = ""
        }

        // Save session token to storage
        _ = secretManager.saveSessionToken(userId: user.userId, token: token)

        let newAccount = Account(
            userId: user.userId,
            hostname: hostname,
            email: user.email,
            orgId: selectedOrgId,
            username: user.username,
            name: user.name
        )

        accountManager.addAccount(newAccount, makeActive: true)

        isAuthenticated = true
        errorMessage = nil
        
        // Fetch server info
        await fetchServerInfo()
    }

    private func ensureOrgIsSelected(preferredOrgId: String? = nil) async throws -> String {
        guard let userId = currentUser?.userId else {
            return ""
        }

        do {
            let orgsResponse = try await apiClient.listUserOrgs(userId: userId)
            organizations = orgsResponse.orgs

            // First, try to use the preferred org ID if provided and it still exists
            if let preferredOrgId = preferredOrgId, !preferredOrgId.isEmpty {
                if let selected = organizations.first(where: { $0.orgId == preferredOrgId }) {
                    currentOrg = selected
                    return selected.orgId
                }
            }

            // Fall back to active account's org ID if no preferred org was provided or it doesn't exist
            if let activeAccount = accountManager.activeAccount {
                if let selected = organizations.first(where: { $0.orgId == activeAccount.orgId }) {
                    currentOrg = selected
                    return selected.orgId
                }
            }

            // If no valid org found, auto-select the first one
            if !organizations.isEmpty {
                let autoSelectedOrg = organizations[0]
                currentOrg = autoSelectedOrg
                return autoSelectedOrg.orgId
            }
        } catch {
            organizations = []
            return ""
        }

        return ""
    }

    func refreshOrganizations() async {
        // Only refresh if authenticated and user ID is available
        guard isAuthenticated, let userId = currentUser?.userId else {
            return
        }

        do {
            let orgsResponse = try await apiClient.listUserOrgs(userId: userId)
            let newOrgs = orgsResponse.orgs

            let currentOrgId = currentOrg?.orgId

            if let currentOrgId = currentOrgId,
                let updatedOrg = newOrgs.first(where: { $0.orgId == currentOrgId })
            {
                // Current org still exists, update it to get latest info
                currentOrg = updatedOrg
            } else if currentOrgId != nil {
                // Current org no longer exists, clear selection
                currentOrg = nil
                accountManager.setUserOrganization(userId: userId, orgId: "")
            }

            // Update organizations list
            organizations = newOrgs

            os_log(
                "Organizations refreshed successfully: %d orgs", log: logger, type: .debug,
                newOrgs.count)
        } catch {
            // Fail gracefully - log error but don't disrupt the UI
            os_log(
                "Failed to refresh organizations in background: %{public}@", log: logger,
                type: .error, error.localizedDescription)
        }
    }

    func switchAccount(userId: String) async {
        guard let accountToSwitchTo = accountManager.accounts[userId] else {
            os_log(
                "Account with userId %{public}@ does not exist", log: logger, type: .error, userId)
            return
        }

        // Disconnect tunnel before switching accounts
        if let tunnelManager = tunnelManager {
            await tunnelManager.disconnect()
        }

        // Always switch account locally first (even if token is missing/invalid)
        accountManager.setActiveUser(userId: userId)
        
        // Reset server down status and error message
        isServerDown = false
        errorMessage = nil
        
        // Clear current user/org data immediately when switching accounts
        // This ensures UI shows the new account's email, not the old account's user name
        currentUser = nil
        currentOrg = nil
        organizations = []
        
        // Keep authenticated state to show UI
        isAuthenticated = true
        
        // Get token (may be nil for invalid accounts)
        let token = secretManager.getSessionToken(userId: userId)
        
        if token == nil {
            // No token available, but still switch the account
            apiClient.updateSessionToken(nil)
            apiClient.updateBaseURL(accountToSwitchTo.hostname)
            errorMessage = "No session token found for this account. Please log in again."
            return
        }
        
        // Update API client with token and hostname
        apiClient.updateSessionToken(token)
        apiClient.updateBaseURL(accountToSwitchTo.hostname)

        // Now validate with the server (but don't revert if it fails)
        
        // Check server health
        var healthCheckFailed = false
        do {
            let isHealthy = try await apiClient.checkHealth()
            if !isHealthy {
                healthCheckFailed = true
            }
        } catch {
            // Health check failed, server is likely down
            healthCheckFailed = true
            os_log(
                "Health check failed when switching accounts: %{public}@", log: logger, type: .error,
                error.localizedDescription)
        }
        
        if healthCheckFailed {
            // Server is down, show message but keep account switched
            isServerDown = true
            errorMessage = "The server appears to be down."
            // currentUser is already cleared above, so UI will show account email
            return
        }

        // Fetch the current user's data
        do {
            let user = try await apiClient.getUser()
            currentUser = user
            // Update stored account with latest user info
            accountManager.updateAccountUserInfo(userId: userId, username: user.username, name: user.name)
            errorMessage = nil  // Clear any previous errors on success
            isServerDown = false  // Clear server down status on success
        } catch {
            // Error fetching user, but keep account switched
            os_log(
                "Error fetching user when switching accounts: %{public}@", log: logger, type: .error,
                error.localizedDescription)
            errorMessage = "Failed to fetch user information: \(error.localizedDescription)"
            // Clear current user/org since we can't fetch them for this account
            currentUser = nil
            currentOrg = nil
            organizations = []
        }

        // Try to select organization (non-fatal if it fails)
        let selectedOrgId: String
        do {
            // Use the account's stored org ID as preferred when switching accounts
            selectedOrgId = try await ensureOrgIsSelected(preferredOrgId: accountToSwitchTo.orgId)
            accountManager.setUserOrganization(userId: userId, orgId: selectedOrgId)
        } catch {
            // Failure to select an organization is non-fatal
            os_log(
                "Error ensuring org when switching accounts: %{public}@", log: logger, type: .error,
                error.localizedDescription)
            selectedOrgId = accountToSwitchTo.orgId
            accountManager.setUserOrganization(userId: userId, orgId: selectedOrgId)
        }
        
        // Fetch server info (non-fatal if it fails)
        await fetchServerInfo()
    }
    
    private func fetchServerInfo() async {
        do {
            let info = try await apiClient.getServerInfo()
            serverInfo = info
        } catch {
            // Log error but don't fail - server info is optional
            os_log(
                "Failed to fetch server info: %{public}@", log: logger, type: .debug,
                error.localizedDescription)
            serverInfo = nil
        }
    }

    func checkOrgAccess(orgId: String) async -> Bool {
        guard let activeAccount = accountManager.activeAccount else {
            return false
        }

        // First, try to fetch the org to check access
        do {
            _ = try await apiClient.getOrg(orgId: orgId)
            return true
        } catch let error as APIError {
            // Check if it's an unauthorized error (401 or 403)
            if case .httpError(let statusCode, _) = error,
                statusCode == 401 || statusCode == 403
            {

                // Try to get org policy to determine access
                if let userId = currentUser?.userId {
                    do {
                        let policyResponse = try await apiClient.checkOrgUserAccess(
                            orgId: orgId, userId: userId)

                        // Determine access based on policyResponse.allowed
                        if policyResponse.allowed {
                            return true
                        }

                        // Access denied - show alert
                        os_log(
                            "Org access denied for org %{public}@: error=%{public}@",
                            log: logger,
                            type: .error,
                            orgId,
                            policyResponse.error ?? "none")

                        // Get hostname for the resolution URL
                        let resolutionURL = "\(activeAccount.hostname)/\(orgId)"

                        // Build message
                        var message = "Access denied due to organization policy violations."
                        if let error = policyResponse.error, !error.isEmpty {
                            message = "Access denied: \(error)"
                        }
                        message +=
                            "\n\nSee more and resolve the issues by visiting: \(resolutionURL)"

                        await MainActor.run {
                            AlertManager.shared.showAlertDialog(
                                title: "Access Denied",
                                message: message
                            )
                        }
                        return false
                    } catch {
                        // Failed to get org policy - show generic unauthorized message
                        os_log(
                            "Failed to get org policy for org %{public}@: %{public}@",
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
        guard let currentUser = currentUser, await checkOrgAccess(orgId: org.orgId) else {
            return
        }

        currentOrg = org

        // Switch org in tunnel if connected
        if let tunnelManager = tunnelManager {
            await tunnelManager.switchOrg(orgId: org.orgId)
        }

        // If access is granted and the tunnel switches,
        // proceed with persisting the selection
        accountManager.setUserOrganization(userId: currentUser.userId, orgId: org.orgId)
    }

    func ensureOlmCredentials(userId: String) async {
        // Check if OLM credentials already exist locally
        if secretManager.hasOlmCredentials(userId: userId) {
            // Verify OLM exists on server by getting the OLM directly
            if let olmIdString = secretManager.getOlmId(userId: userId) {
                do {
                    let orgId = currentOrg?.orgId
                    let olm = try await apiClient.getUserOlm(
                        userId: userId, olmId: olmIdString, orgId: orgId)

                    // Verify the olmId and userId match
                    if olm.olmId == olmIdString && olm.userId == userId {
                        os_log("OLM credentials verified successfully", log: logger, type: .debug)
                        return
                    } else {
                        os_log(
                            "OLM mismatch - returned olmId: %{public}@, userId: %{public}@, stored olmId: %{public}@",
                            log: logger, type: .error, olm.olmId, olm.userId, olmIdString)
                        // Clear invalid credentials
                        _ = secretManager.deleteOlmCredentials(userId: userId)
                    }
                } catch {
                    // If getting OLM fails, the OLM might not exist
                    os_log(
                        "Failed to verify OLM credentials: %{public}@", log: logger, type: .error,
                        error.localizedDescription)
                    // Clear invalid credentials so we can try to create new ones
                    _ = secretManager.deleteOlmCredentials(userId: userId)
                }
            } else {
                // No olmId found, clear credentials
                os_log("Cannot verify OLM - olmId not found", log: logger, type: .error)
                _ = secretManager.deleteOlmCredentials(userId: userId)
            }
        }

        // Before creating new credentials, first attempt to recover them.
        do {
            if let platformFingerprint = tunnelManager?.fingerprintManager
                .getPlatformFingerprintHash()
            {
                let recoveredOlm = try await apiClient.recoverOlmWithFingerprint(
                    userId: userId, platformFingerprint: platformFingerprint)

                _ = secretManager.saveOlmCredentials(
                    userId: userId, olmId: recoveredOlm.olmId, secret: recoveredOlm.secret)

                return
            }

        } catch {

        }

        // If credentials don't exist or were cleared/not recovered, create new ones
        if !secretManager.hasOlmCredentials(userId: userId) {
            do {
                // Use the actual device name (user's computer/device name) for OLM
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
                            NSError(
                                domain: "Pangolin", code: -1,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "Failed to save OLM credentials"
                                ])
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

    func deleteAccount(userId: String) async {
        guard accountManager.accounts[userId] != nil else {
            return
        }

        let isActiveAccount = accountManager.activeAccount?.userId == userId
        let remainingAccounts = accountManager.accounts.filter { $0.key != userId }
        let hasOtherAccounts = !remainingAccounts.isEmpty

        // If deleting the active account, disconnect tunnel first
        if isActiveAccount {
            if let tunnelManager = tunnelManager {
                await tunnelManager.disconnect()
            }

            // Try to call logout endpoint (ignore errors)
            do {
                try await apiClient.logout()
            } catch {
                // Ignore errors - still clear local data
            }
        }

        // Clear local data
        _ = secretManager.deleteSessionToken(userId: userId)
        // TODO: once we support device fingerprint, we should also delete the OLM credentials

        accountManager.removeAccount(userId: userId)

        // If we deleted the active account, switch to another or logout
        if isActiveAccount {
            if hasOtherAccounts, let nextAccount = remainingAccounts.values.first {
                // Switch to the first available account
                await switchAccount(userId: nextAccount.userId)
            } else {
                // No other accounts, fully log out
                apiClient.updateSessionToken(nil)

                isAuthenticated = false
                currentOrg = nil
                organizations = []
                errorMessage = nil
                deviceAuthCode = nil
                deviceAuthLoginURL = nil
            }
        }
    }

    func logout() async {
        guard let activeAccount = accountManager.activeAccount else {
            return
        }

        let userId = activeAccount.userId

        // Check if there are other accounts before removing this one
        let remainingAccounts = accountManager.accounts.filter { $0.key != userId }
        let hasOtherAccounts = !remainingAccounts.isEmpty

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
        _ = secretManager.deleteSessionToken(userId: userId)

        accountManager.removeAccount(userId: userId)

        // If there are other accounts, switch to one of them
        if hasOtherAccounts, let nextAccount = remainingAccounts.values.first {
            // Switch to the first available account
            await switchAccount(userId: nextAccount.userId)
        } else {
            // No other accounts, fully log out
            apiClient.updateSessionToken(nil)

            isAuthenticated = false
            currentOrg = nil
            organizations = []
            errorMessage = nil
            deviceAuthCode = nil
            deviceAuthLoginURL = nil
        }
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
