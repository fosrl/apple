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
    @ObservedObject var onboardingViewModel: MacOnboardingViewModel
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
        onboardingViewModel: MacOnboardingViewModel,
    ) {
        self.configManager = configManager
        self.accountManager = accountManager
        self.apiClient = apiClient
        self.authManager = authManager
        self.tunnelManager = tunnelManager
        self.updater = updater
        self.onboardingViewModel = onboardingViewModel
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    /// Tunnel status caption for the menu bar dropdown.
    private var menuStatusLabel: String {
        "Status: \(tunnelManager.status.displayText)"
    }

    var body: some View {
        Group {
            // When onboarding is needed, show only a minimal menu (don't load full menu)
            if onboardingViewModel.isPresenting {
                Button("Open Pangolin Setup") {
                    openWindow(id: "onboarding")
                }
            } else if authManager.isInitializing {
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
                
                // Error message (for non-server-down, non-session-expired errors)
                if let errorMessage = authManager.errorMessage, !authManager.isServerDown, !authManager.sessionExpired {
                    Text(errorMessage)
                        .foregroundColor(.secondary)
                        .disabled(true)
                    Divider()
                }
                
                if authManager.isAuthenticated && !isLoggedOut {
                    if accountManager.activeAccount != nil {
                        if authManager.sessionExpired {
                            Text("Account Locked")
                                .foregroundColor(.secondary)
                            Button("Log In") {
                                authManager.startDeviceAuthImmediately = true
                                openLoginWindow()
                            }
                            .disabled(authManager.isDeviceAuthInProgress)
                        } else {
                            Text(menuStatusLabel)
                                .foregroundColor(.secondary)
                            ConnectButtonItem(
                                tunnelManager: tunnelManager,
                                onboardingViewModel: onboardingViewModel,
                                openWindow: openWindow
                            )
                        }
                        Divider()
                    }
                }

                if accountManager.accounts.count > 0 {
                    Text("Account")
                        .foregroundColor(.secondary)
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
                    Text("Organization")
                        .foregroundColor(.secondary)
                    OrganizationsMenu(authManager: authManager, tunnelManager: tunnelManager)
                }

            }

            Divider()

            Button("Preferences") {
                openPreferencesWindow()
            }

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
                    openURL("https://pangolin.net/tos")
                }

                Button("Privacy Policy") {
                    openURL("https://pangolin.net/privacy")
                }

                Divider()

                // Version information
                Text(
                    "Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")"
                )
                .foregroundColor(.secondary)

                Button("Check for Updates", action: updater.checkForUpdates)
                    .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
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
        .task {
            await onboardingViewModel.refreshPages()
            if onboardingViewModel.isPresenting, !onboardingViewModel.hasOpenedOnboardingWindowThisSession {
                onboardingViewModel.hasOpenedOnboardingWindowThisSession = true
                openWindow(id: "onboarding")
                await MainActor.run {
                    NSApp.setActivationPolicy(.regular)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        NSApp.windows.first { $0.title == "Pangolin Setup" }?.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }
        .onChange(of: onboardingViewModel.isPresenting) { _, newValue in
            if !newValue {
                onboardingViewModel.hasOpenedOnboardingWindowThisSession = false
                NSApp.setActivationPolicy(.accessory)
            }
        }
        .onAppear {
            // Increment counter to force view recreation and trigger task
            menuOpenCount += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) {
            notification in
            // This fires for every menu, including the app menu next to the Apple logo.
            // Refreshing orgs there republishes state and SwiftUI closes that menu.
            guard let menu = notification.object as? NSMenu, !Self.isApplicationMenu(menu) else { return }
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

    /// True for the menu bar next to the Apple logo and any of its submenus.
    private static func isApplicationMenu(_ menu: NSMenu) -> Bool {
        guard let mainMenu = NSApp.mainMenu else { return false }
        if menu === mainMenu { return true }

        var pending = mainMenu.items.compactMap(\.submenu)
        while let current = pending.popLast() {
            if current === menu { return true }
            pending.append(contentsOf: current.items.compactMap(\.submenu))
        }
        return false
    }

    private func handleMenuOpen() async {
        // Accessory menu bar apps often never become active, so didBecomeActive
        // does not refresh the on-demand start blob. Opening the menu does.
        await tunnelManager.refreshProviderConfigurationIfOnDemandEnabled()

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
        } catch let error as APIError {
            if case .httpError(let statusCode, _) = error, statusCode == 401 || statusCode == 403 {
                // Session expired; leave isLoggedOut false so "Account Locked" / "Log In" show
            } else {
                await MainActor.run {
                    isLoggedOut = true
                }
            }
        } catch {
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
        if !tunnelManager.isNEConnected && tunnelManager.status != .starting {
            return false
        }
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
        if !tunnelManager.isNEConnected && tunnelManager.status != .starting {
            return false
        }
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
    @ObservedObject var onboardingViewModel: MacOnboardingViewModel
    var openWindow: OpenWindowAction

    private var shouldDisableButton: Bool {
        // WireGuard keeps the control enabled when on-demand rules exist.
        if tunnelManager.hasOnDemandRules { return false }
        return tunnelManager.status == .starting && !tunnelManager.isNEConnected
    }

    /// WireGuard macOS toggle labels.
    private var buttonTitle: String {
        if tunnelManager.hasOnDemandRules {
            if tunnelManager.isOnDemandEnabled {
                if tunnelManager.status == .connected || tunnelManager.isNEConnected {
                    return "Disable On-Demand and Disconnect"
                }
                return "Disable On-Demand"
            }
            return "Enable On-Demand"
        }
        return tunnelManager.isNEConnected ? "Disconnect" : "Connect"
    }

    var body: some View {
        Button(buttonTitle) {
            Task { @MainActor in
                let isOn =
                    tunnelManager.isOnDemandEnabled
                    || tunnelManager.isNEConnected
                    || tunnelManager.status == .starting
                    || tunnelManager.status == .registering
                if !isOn {
                    await onboardingViewModel.refreshPages()
                    if onboardingViewModel.isPresenting {
                        onboardingViewModel.hasOpenedOnboardingWindowThisSession = true
                        openWindow(id: "onboarding")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            NSApplication.shared.windows.first { $0.title == "Pangolin Setup" }?.makeKeyAndOrderFront(nil)
                        }
                        return
                    }
                    await tunnelManager.connect()
                } else {
                    await tunnelManager.disconnect()
                }
            }
        }
        .disabled(shouldDisableButton)
        .id("\(tunnelManager.isNEConnected)-\(tunnelManager.isOnDemandEnabled)-\(tunnelManager.hasOnDemandRules)")
    }
}
