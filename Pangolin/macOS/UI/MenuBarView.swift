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
    @ObservedObject var resourceManager: ResourceManager
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
        resourceManager: ResourceManager
    ) {
        self.configManager = configManager
        self.accountManager = accountManager
        self.apiClient = apiClient
        self.authManager = authManager
        self.tunnelManager = tunnelManager
        self.updater = updater
        self.onboardingViewModel = onboardingViewModel
        self.resourceManager = resourceManager
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Group {
            // When onboarding is needed, show only a minimal menu (don't load full menu)
            if onboardingViewModel.isPresenting {
                Button("Open CNDF-VPN Setup") {
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
                            Text(tunnelManager.status.displayText)
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
                    ResourcesMenu(resourceManager: resourceManager)
                }

            }

            Divider()

            // More submenu
            Menu("More") {
                // Support section
                Text("Support")
                    .foregroundColor(.secondary)

                Button("How CNDF-VPN Works") {
                    openURL("https://docs.pangolin.net/about/how-pangolin-works")
                }

                Button("Documentation") {
                    openURL("https://docs.pangolin.net/")
                }

                Divider()

                // Legal links will be added when available

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
        .task {
            await onboardingViewModel.refreshPages()
            if onboardingViewModel.isPresenting, !onboardingViewModel.hasOpenedOnboardingWindowThisSession {
                onboardingViewModel.hasOpenedOnboardingWindowThisSession = true
                openWindow(id: "onboarding")
                await MainActor.run {
                    NSApp.setActivationPolicy(.regular)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        NSApp.windows.first { $0.title == "CNDF-VPN Setup" }?.makeKeyAndOrderFront(nil)
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

        // Refresh organizations and resources in background
        if authManager.isAuthenticated {
            await authManager.refreshOrganizations()
            await resourceManager.refreshIfNeeded()
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
            window.identifier?.rawValue == "main" || window.title == "CNDF-VPN"
        }

        if let window = existingWindow {
            // Window exists - close any duplicates first
            let allMainWindows = NSApplication.shared.windows.filter { w in
                (w.identifier?.rawValue == "main" || w.title == "CNDF-VPN") && w != window
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
                    $0.identifier?.rawValue == "main" || $0.title == "CNDF-VPN"
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

struct ResourcesMenu: View {
    @ObservedObject var resourceManager: ResourceManager

    var body: some View {
        Menu("Resources") {
            if resourceManager.isLoading {
                Text("Loading...")
                    .foregroundColor(.secondary)
            } else if resourceManager.resourceGroups.isEmpty {
                Text("No resources")
                    .foregroundColor(.secondary)
            } else {
                ForEach(resourceManager.resourceGroups) { group in
                    Section(group.label) {
                        ForEach(group.categories) { category in
                            Menu(category.name) {
                                ForEach(category.resources) { item in
                                    ResourceMenuItem(
                                        item: item,
                                        resourceManager: resourceManager
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ResourceMenuItem: View {
    let item: CategorizedResource
    @ObservedObject var resourceManager: ResourceManager
    @State private var targets: [Target]?
    @State private var isLoadingTargets = false

    var body: some View {
        Menu(item.displayName) {
            if let subdomain = item.resource.subdomain, !subdomain.isEmpty {
                Text("Alias: \(subdomain)")
                    .foregroundColor(.secondary)
            }

            Text("Protocol: \(item.resource.protocol)")
                .foregroundColor(.secondary)

            if let proxyPort = item.resource.proxyPort {
                Text("Port: \(proxyPort)")
                    .foregroundColor(.secondary)
            }

            Divider()

            if isLoadingTargets {
                Text("Loading targets...")
                    .foregroundColor(.secondary)
            } else if let targets = targets {
                if targets.isEmpty {
                    Text("No targets")
                        .foregroundColor(.secondary)
                } else {
                    let tcpPorts = targets
                        .filter { ($0.method ?? "").lowercased() == "tcp" }
                        .compactMap { $0.port }
                    let udpPorts = targets
                        .filter { ($0.method ?? "").lowercased() == "udp" }
                        .compactMap { $0.port }
                    let icmpTargets = targets
                        .filter { ($0.method ?? "").lowercased() == "icmp" }

                    if !tcpPorts.isEmpty {
                        Text("TCP: \(tcpPorts.map(String.init).joined(separator: ", "))")
                            .foregroundColor(.secondary)
                    }
                    if !udpPorts.isEmpty {
                        Text("UDP: \(udpPorts.map(String.init).joined(separator: ", "))")
                            .foregroundColor(.secondary)
                    }
                    if !icmpTargets.isEmpty {
                        Text("ICMP")
                            .foregroundColor(.secondary)
                    }
                    if tcpPorts.isEmpty && udpPorts.isEmpty && icmpTargets.isEmpty {
                        ForEach(targets) { target in
                            Text("\(target.ip):\(target.port ?? 0)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .task {
            isLoadingTargets = true
            targets = await resourceManager.fetchTargets(for: item.resource.resourceId)
            isLoadingTargets = false
        }
    }
}

struct ConnectButtonItem: View {
    @ObservedObject var tunnelManager: TunnelManager
    @ObservedObject var onboardingViewModel: MacOnboardingViewModel
    var openWindow: OpenWindowAction

    private var shouldDisableButton: Bool {
        return tunnelManager.status == .starting
    }

    var body: some View {
        Button(tunnelManager.isNEConnected ? "Disconnect" : "Connect") {
            Task { @MainActor in
                if !tunnelManager.isNEConnected {
                    await onboardingViewModel.refreshPages()
                    if onboardingViewModel.isPresenting {
                        onboardingViewModel.hasOpenedOnboardingWindowThisSession = true
                        openWindow(id: "onboarding")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            NSApplication.shared.windows.first { $0.title == "CNDF-VPN Setup" }?.makeKeyAndOrderFront(nil)
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
    }
}
