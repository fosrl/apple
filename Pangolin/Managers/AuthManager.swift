//
//  AuthManager.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import AppKit
import Combine
import Foundation
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

        if let activeAccount = accountManager.activeAccount,
            let token = secretManager.getSessionToken(userId: activeAccount.userId)
        {

            apiClient.updateSessionToken(token)

            // Always fetch the latest user info to verify the user exists and update stored info
            do {
                let user = try await apiClient.getUser()
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
                // Get device name
                let deviceName = ProcessInfo.processInfo.hostName

                let hostname = loginApiClient.currentBaseURL

                let startResponse = try await loginApiClient.startDeviceAuth(
                    applicationName: "Pangolin macOS Client",
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

                    try await Task.sleep(nanoseconds: 3_000_000_000)  // 3 seconds

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

        // Disconnect tunnel on successful login to ensure clean state
        if let tunnelManager = tunnelManager {
            await tunnelManager.disconnect()
        }

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

        // Ensure OLM credentials exist for this device-account combo
        await ensureOlmCredentials(userId: user.userId)

        let newAccount = Account(
            userId: user.userId,
            hostname: hostname,
            email: user.email,
            orgId: selectedOrgId,
        )

        accountManager.addAccount(newAccount, makeActive: true)

        isAuthenticated = true
        errorMessage = nil
    }

    private func ensureOrgIsSelected() async throws -> String {
        guard let userId = currentUser?.userId else {
            return ""
        }

        do {
            let orgsResponse = try await apiClient.listUserOrgs(userId: userId)
            organizations = orgsResponse.orgs

            if let activeAccount = accountManager.activeAccount {
                if let selected = organizations.first(where: { $0.orgId == activeAccount.orgId }) {
                    currentOrg = selected
                    return selected.orgId
                }
            }

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
        isAuthenticated = false
        defer {
            isAuthenticated = true
        }

        guard let accountToSwitchTo = accountManager.accounts[userId] else {
            os_log(
                "Account with userId %{public}@ does not exist", log: logger, type: .error, userId)
            return
        }

        guard let token = secretManager.getSessionToken(userId: userId) else {
            os_log(
                "Session token does not exist for %{public}@", log: logger, type: .error, userId)
            return
        }

        // Disconnect tunnel before switching accounts
        if let tunnelManager = tunnelManager {
            await tunnelManager.disconnect()
        }

        let prevToken = secretManager.getSessionToken(userId: accountManager.activeUserId)
        let prevBaseURL = apiClient.currentBaseURL

        // Update the API client with the new account's values and
        // fetch the current user's data
        do {
            apiClient.updateSessionToken(token)
            apiClient.updateBaseURL(accountToSwitchTo.hostname)

            let user = try await apiClient.getUser()
            currentUser = user
        } catch {
            // In case a failure happens when switching, log it
            // and switch the API client back to the previous
            // values.
            os_log(
                "Error switching accounts: %{public}@", log: logger, type: .error,
                error.localizedDescription)

            apiClient.updateSessionToken(prevToken)
            apiClient.updateBaseURL(prevBaseURL)

            return
        }

        let selectedOrgId: String
        do {
            selectedOrgId = try await ensureOrgIsSelected()
        } catch {
            // Failure to select an organization is non-fatal,
            // so let's just indicate the failure through the logs
            // and move on.
            os_log(
                "Error ensuring org accounts: %{public}@", log: logger, type: .error,
                error.localizedDescription)
            selectedOrgId = ""
        }

        accountManager.setActiveUser(userId: userId)
        accountManager.setUserOrganization(userId: userId, orgId: selectedOrgId)
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
                    let olm = try await apiClient.getUserOlm(userId: userId, olmId: olmIdString)

                    // Verify the olmId and userId match
                    if olm.olmId == olmIdString && olm.userId == userId {
                        os_log("OLM credentials verified successfully", log: logger, type: .debug)
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

    func logout() async {
        guard let activeAccount = accountManager.activeAccount else {
            return
        }

        let userId = activeAccount.userId

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
        _ = secretManager.deleteOlmCredentials(userId: userId)

        accountManager.removeAccount(userId: userId)

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
