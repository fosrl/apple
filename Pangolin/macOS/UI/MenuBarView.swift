//
//  MenuBarView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import AppKit
import Sparkle
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var apiClient: APIClient
    @ObservedObject var authManager: AuthManager
    @ObservedObject var tunnelManager: TunnelManager
    let updater: SPUUpdater
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var menuOpenCount = 0
    @State private var isLoggedOut = false

    init(
        configManager: ConfigManager,
        accountManager: AccountManager,
        apiClient: APIClient,
        authManager: AuthManager,
        tunnelManager: TunnelManager,
        updater: SPUUpdater,
    ) {
        self.configManager = configManager
        self.accountManager = accountManager
        self.apiClient = apiClient
        self.authManager = authManager
        self.tunnelManager = tunnelManager
        self.updater = updater
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Group {
            // Show loading state during initialization
            if authManager.isInitializing {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading...")
                        .foregroundColor(.secondary)
                }
            } else {
                // Server down message
                if authManager.isServerDown {
                    Text("The server appears to be down.")
                        .foregroundColor(.secondary)
                        .disabled(true)
                    Divider()
                }
                
                // Error message (for non-server-down errors)
                if let errorMessage = authManager.errorMessage, !authManager.isServerDown {
                    Text(errorMessage)
                        .foregroundColor(.secondary)
                        .disabled(true)
                    Divider()
                }
                
                if authManager.isAuthenticated && !isLoggedOut {
                    if accountManager.activeAccount != nil {
                        Text(tunnelManager.status.displayText)
                            .foregroundColor(.secondary)

                        // Connect toggle (when authenticated and not logged out)
                        ConnectButtonItem(tunnelManager: tunnelManager)

                        Divider()
                    }
                }

                if accountManager.accounts.count > 0 {
                    AccountsMenu(
                        authManager: authManager,
                        accountManager: accountManager,
                        tunnelManager: tunnelManager,
                        openLoginWindow: openLoginWindow
                    )
                    .id(menuOpenCount)  // Force view recreation to trigger task
                    .task {
                        // Handle menu open logic when menu opens (only if authenticated)
                        if authManager.isAuthenticated {
                            await handleMenuOpen()
                        }
                    }
                } else {
                    Button("Login") {
                        openLoginWindow()
                    }
                }

                if authManager.isAuthenticated && !isLoggedOut {
                    OrganizationsMenu(authManager: authManager, tunnelManager: tunnelManager)
                }

            }

            Divider()

            // More submenu
            Menu("More") {
                // Support section
                Text("Support")
                    .foregroundColor(.secondary)

                Button("How Pangolin Works") {
                    openURL("https://docs.pangolin.net/about/how-pangolin-works")
                }

                Button("Documentation") {
                    openURL("https://docs.pangolin.net/")
                }

                Divider()

                // Copyright
                Text("© \(String(Calendar.current.component(.year, from: Date()))) Fossorial, Inc.")
                    .foregroundColor(.secondary)

                Button("Terms of Service") {
                    openURL("https://pangolin.net/terms-of-service.html")
                }

                Button("Privacy Policy") {
                    openURL("https://pangolin.net/privacy-policy.html")
                }

                Divider()

                // Version information
                Text(
                    "Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")"
                )
                .foregroundColor(.secondary)

                Button("Check for Updates", action: updater.checkForUpdates)
                    .disabled(!checkForUpdatesViewModel.canCheckForUpdates)

                Button("Preferences") {
                    openPreferencesWindow()
                }
            }

            Divider()

            // Personal license notice
            if let serverInfo = authManager.serverInfo,
               serverInfo.build == "enterprise",
               let licenseType = serverInfo.enterpriseLicenseType,
               licenseType.lowercased() == "personal" {
                Text("Licensed for personal use only.")
                    .foregroundColor(.secondary)
                    .disabled(true)
            }
            
            // Unlicensed enterprise notice
            if let serverInfo = authManager.serverInfo,
               serverInfo.build == "enterprise",
               !serverInfo.enterpriseLicenseValid {
                Text("This server is unlicensed.")
                    .foregroundColor(.secondary)
                    .disabled(true)
            }
            
            // OSS community edition notice
            if let serverInfo = authManager.serverInfo,
               serverInfo.build == "oss",
               !serverInfo.supporterStatusValid {
                Text("Community Edition. Consider supporting.")
                    .foregroundColor(.secondary)
                    .disabled(true)
            }

            Divider()

            // Quit
            Button("Quit") {
                Task {
                    // Disconnect tunnel before quitting
                    await tunnelManager.disconnect()
                    // Small delay to ensure disconnect completes
                    try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
                    await MainActor.run {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
            .keyboardShortcut("q")
        }
        .onAppear {
            // Increment counter to force view recreation and trigger task
            menuOpenCount += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) {
            _ in
            // Also handle menu open logic when menu begins tracking (menu is opening)
            if authManager.isAuthenticated {
                Task {
                    await handleMenuOpen()
                }
            }
        }
        .onChange(of: authManager.isAuthenticated) { oldValue, newValue in
            // Reset logged out state when authentication state changes
            if newValue {
                isLoggedOut = false
            }
        }
    }

    private func handleMenuOpen() async {
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
        
        await MainActor.run {
            if healthCheckFailed {
                authManager.isServerDown = true
                authManager.errorMessage = "The server appears to be down. Showing last known information."
            } else {
                authManager.isServerDown = false
                authManager.errorMessage = nil
            }
        }
        
        // If server is down, don't try to fetch user data
        if healthCheckFailed {
            return
        }
        
        // First, try to get the user to verify session is still valid
        do {
            let user = try await apiClient.getUser()
            // If successful, update user and clear logged out state
            await MainActor.run {
                authManager.currentUser = user
                isLoggedOut = false
                // Update stored account with latest user info
                if let activeAccount = accountManager.activeAccount {
                    accountManager.updateAccountUserInfo(
                        userId: activeAccount.userId,
                        username: user.username,
                        name: user.name
                    )
                }
            }

            // await tunnelManager.disconnect()
        } catch {
            // If getting user fails, mark as logged out
            await MainActor.run {
                isLoggedOut = true
            }
        }

        // Refresh organizations in background
        if authManager.isAuthenticated {
            await authManager.refreshOrganizations()
        }
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openLoginWindow() {
        // Show app in dock when opening window
        DispatchQueue.main.async {
            guard NSApp.activationPolicy() != .regular else { return }
            NSApp.setActivationPolicy(.regular)
        }

        // Find existing window by identifier or title
        let existingWindow = NSApplication.shared.windows.first { window in
            window.identifier?.rawValue == "main" || window.title == "Pangolin"
        }

        if let window = existingWindow {
            // Window exists - close any duplicates first
            let allMainWindows = NSApplication.shared.windows.filter { w in
                (w.identifier?.rawValue == "main" || w.title == "Pangolin") && w != window
            }
            for duplicateWindow in allMainWindows {
                duplicateWindow.close()
            }

            // Configure window
            var styleMask = window.styleMask
            styleMask.remove([.miniaturizable, .resizable])
            styleMask.insert([.titled, .closable])
            window.styleMask = styleMask

            // Hide minimize and zoom buttons, keep only close button
            if let minimizeButton = window.standardWindowButton(.miniaturizeButton) {
                minimizeButton.isHidden = true
            }
            if let zoomButton = window.standardWindowButton(.zoomButton) {
                zoomButton.isHidden = true
            }
            if let closeButton = window.standardWindowButton(.closeButton) {
                closeButton.isHidden = false
            }

            // Bring existing window to front
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)

            // Ensure identifier is set
            if window.identifier?.rawValue != "main" {
                window.identifier = NSUserInterfaceItemIdentifier("main")
            }
        } else {
            // No window exists - open a new one
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)

            // Bring the newly created window to front after it's created
            // Use a small delay to ensure the window is created, but check for existence first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let window = NSApplication.shared.windows.first(where: {
                    $0.identifier?.rawValue == "main" || $0.title == "Pangolin"
                }) {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    private func openPreferencesWindow() {
        // Show app in dock when opening window
        DispatchQueue.main.async {
            guard NSApp.activationPolicy() != .regular else { return }
            NSApp.setActivationPolicy(.regular)
        }

        // Find existing preferences window by identifier
        let existingWindow = NSApplication.shared.windows.first { window in
            window.identifier?.rawValue == "preferences"
        }

        if let window = existingWindow {
            // Window exists - close any duplicates first
            let allPreferencesWindows = NSApplication.shared.windows.filter { w in
                w.identifier?.rawValue == "preferences" && w != window
            }
            for duplicateWindow in allPreferencesWindows {
                duplicateWindow.close()
            }

            // Bring existing window to front
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // No window exists - open a new one
            openWindow(id: "preferences")
            NSApp.activate(ignoringOtherApps: true)

            // Bring the newly created window to front after it's created
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let window = NSApplication.shared.windows.first(where: {
                    $0.identifier?.rawValue == "preferences"
                }) {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }
}

struct OrganizationsMenu: View {
    @ObservedObject var authManager: AuthManager
    @ObservedObject var tunnelManager: TunnelManager

    private var organizations: [Organization] {
        authManager.organizations
    }

    private var currentOrgId: String? {
        authManager.currentOrg?.orgId
    }

    private var menuTitle: String {
        if let currentOrg = authManager.currentOrg {
            return currentOrg.name
        }
        return "Organizations"
    }

    private var shouldDisableOrgButtons: Bool {
        switch tunnelManager.status {
        case .starting, .registering:
            return true
        default:
            return false
        }
    }

    var body: some View {
        Menu {
            // Show organization count
            Text(
                organizations.count == 1 ? "1 Organization" : "\(organizations.count) Organizations"
            )
            .foregroundColor(.secondary)

            Divider()

            ForEach(organizations, id: \.orgId) { org in
                Button {
                    Task {
                        await authManager.selectOrganization(org)
                    }
                } label: {
                    HStack {
                        Text(org.name)
                        if currentOrgId == org.orgId {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(shouldDisableOrgButtons)
            }
        } label: {
            Text(menuTitle)
        }
    }
}

struct AccountsMenu: View {
    @ObservedObject var authManager: AuthManager
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var tunnelManager: TunnelManager

    let openLoginWindow: () -> Void

    private var accounts: [Account] {
        return Array(accountManager.accounts.values)
    }

    private var emailCounts: [String: Int] {
        Dictionary(grouping: accounts, by: { $0.email }).mapValues { $0.count }
    }

    private var currentAccountUserId: String? {
        accountManager.activeAccount?.userId
    }

    private var menuTitle: String {
        if let user = authManager.currentUser {
            return user.displayName
        }
        if let activeAccount = accountManager.activeAccount {
            return activeAccount.displayName
        }

        return "Select Account"
    }

    private var shouldDisableAccountButton: Bool {
        switch tunnelManager.status {
        case .starting, .registering:
            return true
        default:
            return false
        }
    }

    private func formatAccountLabel(account: Account) -> String {
        let displayName = account.displayName
        let count = emailCounts[account.email, default: 0]

        // If multiple accounts share the same email, show hostname to differentiate
        let text =
            count > 1
            ? "\(displayName) (\(account.hostname))"
            : displayName

        return text
    }

    var body: some View {
        Menu {
            Text(
                "Available Accounts"
            )
            .foregroundColor(.secondary)

            Divider()

            ForEach(accounts, id: \.userId) { account in
                let accountLabelText = formatAccountLabel(account: account)

                Button {
                    Task {
                        // TODO: switch account impl here
                        await authManager.switchAccount(userId: account.userId)
                    }
                } label: {
                    HStack {
                        Text(accountLabelText)
                        if currentAccountUserId == account.userId {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(shouldDisableAccountButton)
            }

            Divider()

            Button("Add Account") {
                openLoginWindow()
            }

            if accountManager.activeAccount != nil {
                Button("Logout") {
                    Task {
                        await authManager.logout()
                    }
                }
            }
        } label: {
            Text(menuTitle)
        }
    }
}

struct ConnectButtonItem: View {
    @ObservedObject var tunnelManager: TunnelManager
    
    private var shouldDisableButton: Bool {
        // Only disable connect button when starting
        // Disconnect button should be enabled during registering
        return tunnelManager.status == .starting
    }

    var body: some View {
        Button(tunnelManager.isNEConnected ? "Disconnect" : "Connect") {
            Task {
                if !tunnelManager.isNEConnected {
                    await tunnelManager.connect()
                } else {
                    await tunnelManager.disconnect()
                }
            }
        }
        .disabled(shouldDisableButton)
    }
}
