import AppKit
import Combine
import Sparkle
import SwiftUI

/// Actions started from the menu that are still running. Shared by the menu and
/// its submenus, which are hosted in separate windows, so both show the same
/// spinners.
@MainActor
final class MenuBarActivity: ObservableObject {
    @Published var pendingTunnelOn: Bool?
    @Published private(set) var switchingAccountId: String?
    @Published private(set) var switchingOrgId: String?
    @Published private(set) var isLoggingOut = false

    private let authManager: AuthManager
    private let accountManager: AccountManager
    private let tunnelManager: TunnelManager

    init(authManager: AuthManager, accountManager: AccountManager, tunnelManager: TunnelManager) {
        self.authManager = authManager
        self.accountManager = accountManager
        self.tunnelManager = tunnelManager
    }

    var isSwitching: Bool {
        switchingAccountId != nil || switchingOrgId != nil || isLoggingOut
    }

    /// Account and org changes restart the tunnel, so hold them while it's starting.
    var isTunnelStarting: Bool {
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

    func switchAccount(to account: Account) {
        guard !isSwitching, accountManager.activeAccount?.userId != account.userId else { return }
        switchingAccountId = account.userId
        Task {
            defer { switchingAccountId = nil }
            await authManager.switchAccount(userId: account.userId)
        }
    }

    func selectOrganization(_ org: Organization) {
        guard !isSwitching, authManager.currentOrg?.orgId != org.orgId else { return }
        switchingOrgId = org.orgId
        Task {
            defer { switchingOrgId = nil }
            await authManager.selectOrganization(org)
        }
    }

    func logOut() {
        guard !isSwitching else { return }
        isLoggingOut = true
        Task {
            defer { isLoggingOut = false }
            await authManager.logout()
        }
    }
}

/// Content of the menu bar panel. Hosted in a `.window` style MenuBarExtra so
/// it stays open while the tunnel, account, or organization changes and can
/// show progress for them.
struct MenuBarView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var apiClient: APIClient
    @ObservedObject var authManager: AuthManager
    @ObservedObject var tunnelManager: TunnelManager
    let updater: SPUUpdater
    @ObservedObject var onboardingViewModel: MacOnboardingViewModel
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    @StateObject private var activity: MenuBarActivity
    @StateObject private var submenus = MenuSubmenuController()
    @Environment(\.openWindow) private var openWindow
    @State private var isLoggedOut = false
    @State private var isMenuVisible = false
    @State private var lastContentHeight: CGFloat = 0
    @State private var showsLoading = false
    @State private var loadingStartedAt: Date?
    @State private var displayedTunnelState: TunnelDisplayState?
    /// Set once a user-requested disconnect finishes, so its result shows at once.
    @State private var showsIdleStateImmediately = false

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
        _activity = StateObject(
            wrappedValue: MenuBarActivity(
                authManager: authManager,
                accountManager: accountManager,
                tunnelManager: tunnelManager))
    }

    var body: some View {
        // Content and spinner swap in place, and the spinner keeps the height the
        // content last had, so the menu doesn't change size while loading.
        ZStack(alignment: .top) {
            if showsLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.menuBlur)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    mainContent

                    MenuSeparator()

                    MenuItem(title: "Quit Pangolin", shortcut: "⌘Q") {
                        dismissMenu()
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
                    .keyboardShortcut("q", modifiers: .command)

                    if !licenseNotices.isEmpty {
                        MenuSeparator()
                        ForEach(licenseNotices, id: \.self) { notice in
                            MenuLabel(text: notice)
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    lastContentHeight = height
                }
                .transition(.menuBlur)
            }
        }
        .frame(height: showsLoading ? loadingHeight : nil)
        // The outgoing content stays live while it blurs out, so block the
        // pointer from reaching it.
        .overlay {
            if showsLoading {
                Color.clear
                    .contentShape(Rectangle())
                    .onHover { _ in }
            }
        }
        .padding(MenuMetrics.panelPadding)
        .frame(width: MenuMetrics.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        // The window follows the content's animated height, so layout changes
        // resize the menu smoothly instead of jumping.
        .animation(Self.layoutAnimation, value: layoutSignature)
        .environment(\.submenuController, submenus)
        .environment(\.menuSuppressesHover, submenus.isAimingAtSubmenu)
        .background(MenuWindowVisibilityReader { isMenuVisible = $0 })
        .task(id: isMenuVisible) {
            guard isMenuVisible else {
                submenus.close()
                return
            }
            if authManager.isAuthenticated {
                await handleMenuOpen()
            }
        }
        .task(id: liveTunnelState) {
            await settleTunnelState(liveTunnelState)
        }
        .onChange(of: tunnelState.isConnected) { _, connected in
            // The sites list is only offered while connected.
            if !connected, submenus.openID == Self.sitesSubmenuID { submenus.close() }
        }
        .onChange(of: isBusy, initial: true) { _, busy in
            updateLoading(busy: busy)
        }
        .onChange(of: authManager.isAuthenticated) { oldValue, newValue in
            // Reset logged out state when authentication state changes
            if newValue {
                isLoggedOut = false
            }
        }
    }

    // MARK: - Loading

    private static let layoutAnimation = Animation.smooth(duration: 0.35)

    /// The spinner stays up at least this long, so quick switches don't flash.
    private static let minimumLoadingDuration: TimeInterval = 0.7

    /// The content's last measured height, or a stand-in before it has been
    /// measured, e.g. while loading at launch.
    private var loadingHeight: CGFloat {
        lastContentHeight > 0 ? lastContentHeight : 180
    }

    private func updateLoading(busy: Bool) {
        if busy {
            submenus.isSuspended = true
            loadingStartedAt = Date()
            withAnimation(Self.layoutAnimation) { showsLoading = true }
            return
        }
        guard showsLoading else { return }
        let elapsed = Date().timeIntervalSince(loadingStartedAt ?? .distantPast)
        let remaining = max(0, Self.minimumLoadingDuration - elapsed)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(remaining))
            // Another switch may have started while waiting.
            guard !isBusy else { return }
            withAnimation(Self.layoutAnimation) { showsLoading = false }
            submenus.isSuspended = false
        }
    }

    /// Everything that adds or removes rows. Changes to it animate the menu's size.
    private var layoutSignature: [Bool] {
        [
            showsLoading,
            onboardingViewModel.isPresenting,
            showsTunnelSection,
            showsOrganizationSection,
            showsExitNodeRow,
            accountManager.accounts.isEmpty,
            authManager.sessionExpired,
            authManager.isServerDown,
            authManager.errorMessage != nil,
            tunnelManager.connectionErrorMessage != nil,
            licenseNotices.isEmpty,
        ]
    }

    /// While loading or switching, only a spinner is shown.
    private var isBusy: Bool {
        guard !onboardingViewModel.isPresenting else { return false }
        return authManager.isInitializing || activity.isSwitching
    }

    @ViewBuilder
    private var mainContent: some View {
        if onboardingViewModel.isPresenting {
            MenuItem(title: "Open Pangolin Setup…") {
                openOnboardingWindow()
            }
        } else {
            if showsTunnelSection {
                tunnelStatusRow
                tunnelToggleRow
                tunnelNotices
                MenuSeparator()
            }
            serverNotices
            accountSection
            if showsOrganizationSection {
                organizationSection
            }
        }

        MenuSeparator()

        MenuItem(title: "Preferences…", shortcut: "⌘,") {
            openPreferencesWindow()
        }
        .keyboardShortcut(",", modifiers: .command)

        MenuSubmenuItem(id: "more", title: "More", controller: submenus) {
            MoreSubmenu(
                checkForUpdatesViewModel: checkForUpdatesViewModel,
                openURL: openURL,
                checkForUpdates: {
                    dismissMenu()
                    updater.checkForUpdates()
                })
        }
    }

    // MARK: - Tunnel

    private var showsTunnelSection: Bool {
        authManager.isAuthenticated && !isLoggedOut && accountManager.activeAccount != nil
    }

    private var isTunnelOn: Bool {
        tunnelManager.isOnDemandEnabled
            || tunnelManager.isNEConnected
            || tunnelManager.status == .starting
            || tunnelManager.status == .registering
    }

    private var isToggleDisabled: Bool {
        if activity.pendingTunnelOn != nil || activity.isSwitching { return true }
        // A locked account can still turn the tunnel off, but not on.
        if activeAccountNeedsLogin && !isTunnelOn { return true }
        // WireGuard keeps the control enabled when on-demand rules exist.
        if tunnelManager.hasOnDemandRules { return false }
        return tunnelManager.status == .starting && !tunnelManager.isNEConnected
    }

    /// The tunnel state as reported right now. With on-demand, macOS can move
    /// through several of these within a second while it brings the tunnel up.
    private var liveTunnelState: TunnelDisplayState {
        // A requested change reads as in progress until the tunnel settles.
        switch activity.pendingTunnelOn {
        case false?: return .disconnecting
        case true?: return .registering
        case nil: break
        }
        switch tunnelManager.status {
        case .starting, .registering:
            return .registering
        case .connected:
            return .connected(onDemand: tunnelManager.isOnDemandEnabled)
        case .disconnected:
            if authManager.sessionExpired { return .locked }
            return .disconnected(onDemand: tunnelManager.isOnDemandEnabled)
        }
    }

    /// What the status line shows: `liveTunnelState`, except that falling from
    /// registering or connected back to idle only shows once it has held for a
    /// moment, which hides the brief drops on-demand makes while connecting.
    private var tunnelState: TunnelDisplayState {
        displayedTunnelState ?? liveTunnelState
    }

    /// How long a drop has to hold before the status line shows it.
    private static let dropDelay: Duration = .seconds(1.5)

    /// Brief drops aren't shown: falling from registering or connected back to
    /// idle, or from connected back to registering (which can happen for a
    /// moment when the tunnel's configuration is reloaded).
    private static func holdsBeforeShowing(
        _ live: TunnelDisplayState, after shown: TunnelDisplayState
    ) -> Bool {
        if live.isIdle { return shown == .registering || shown.isConnected }
        return live == .registering && shown.isConnected
    }

    private func settleTunnelState(_ live: TunnelDisplayState) async {
        // A stop the user asked for has already been waited out.
        if live.isIdle, showsIdleStateImmediately {
            showsIdleStateImmediately = false
            displayedTunnelState = live
            return
        }
        if let shown = displayedTunnelState, Self.holdsBeforeShowing(live, after: shown) {
            try? await Task.sleep(for: Self.dropDelay)
            guard !Task.isCancelled else { return }
        }
        displayedTunnelState = live
    }

    /// WireGuard macOS toggle labels.
    private var tunnelActionTitle: String {
        // Disconnecting keeps the "on" wording, so the label changes once it's done.
        let isUp = tunnelState.isTransitioning || tunnelState.isConnected
        if tunnelManager.hasOnDemandRules {
            if tunnelManager.isOnDemandEnabled {
                return isUp ? "Disable On-Demand and Disconnect" : "Disable On-Demand"
            }
            return "Enable On-Demand"
        }
        return isUp || tunnelManager.isNEConnected ? "Disconnect" : "Connect"
    }

    /// The status line. Once connected, hovering it lists the sites and their status.
    @ViewBuilder
    private var tunnelStatusRow: some View {
        if tunnelState.isConnected {
            MenuSubmenuItem(id: Self.sitesSubmenuID, controller: submenus) {
                SitesSubmenu(
                    olmStatusManager: tunnelManager.olmStatusManager,
                    tunnelManager: tunnelManager,
                    controller: submenus.child,
                    openStatusPanel: { openPreferencesWindow(section: .olmStatus) })
            } label: {
                tunnelStatusLabel
            }
        } else {
            tunnelStatusLabel
                .font(MenuMetrics.font)
                .padding(.horizontal, MenuMetrics.rowHorizontalPadding)
                .frame(maxWidth: .infinity, minHeight: MenuMetrics.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { submenus.pointerEnteredOtherRow() }
                }
        }
    }

    private static let sitesSubmenuID = "sites"

    private var tunnelStatusLabel: some View {
        HStack(spacing: 8) {
            MenuStatusDot(color: tunnelState.color)

            Text(tunnelState.text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)

            if tunnelState.isTransitioning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: tunnelState)
    }

    private var tunnelToggleRow: some View {
        MenuToggleRow(
            title: tunnelActionTitle,
            isOn: Binding(
                get: { activity.pendingTunnelOn ?? isTunnelOn },
                set: { setTunnel(on: $0) }
            ),
            tint: tunnelState.toggleTint
        )
        .disabled(isToggleDisabled)
    }

    /// The active account has to log in again: its session expired or none is saved.
    private var activeAccountNeedsLogin: Bool {
        guard let account = accountManager.activeAccount else { return false }
        return authManager.sessionExpired || !authManager.hasSession(userId: account.userId)
    }

    @ViewBuilder
    private var tunnelNotices: some View {
        if activeAccountNeedsLogin {
            MenuLabel(
                text: "Your session expired. Log in again to connect.",
                systemImage: "lock.fill")
            MenuItem(title: "Log In…") {
                openLoginWindow(renewing: accountManager.activeAccount?.hostname)
            }
            .disabled(authManager.isDeviceAuthInProgress)
        } else if let message = tunnelManager.connectionErrorMessage {
            MenuLabel(text: message, systemImage: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private func setTunnel(on: Bool) {
        guard activity.pendingTunnelOn == nil, on != isTunnelOn else { return }
        activity.pendingTunnelOn = on
        showsIdleStateImmediately = false
        Task { @MainActor in
            defer { activity.pendingTunnelOn = nil }
            if on {
                await onboardingViewModel.refreshPages()
                if onboardingViewModel.isPresenting {
                    openOnboardingWindow()
                    return
                }
                await tunnelManager.connect()
            } else {
                // Wait for the tunnel to actually stop. With on-demand, macOS
                // reports several states on the way down, and returning early
                // would show them.
                await tunnelManager.stopCompletely()
                showsIdleStateImmediately = true
            }
        }
    }

    // MARK: - Server notices

    @ViewBuilder
    private var serverNotices: some View {
        if authManager.isServerDown {
            MenuLabel(
                text: "The server appears to be down.",
                systemImage: "exclamationmark.triangle.fill", tint: .orange)
            MenuSeparator()
        } else if let errorMessage = authManager.errorMessage, !activeAccountNeedsLogin {
            // Errors about logging in again are covered by the tunnel notices.
            MenuLabel(text: errorMessage, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            MenuSeparator()
        }
    }

    // MARK: - Account and organization

    private var accountTitle: String {
        if let user = authManager.currentUser {
            return user.displayName
        }
        if let activeAccount = accountManager.activeAccount {
            return activeAccount.displayName
        }
        return "Select Account"
    }

    @ViewBuilder
    private var accountSection: some View {
        if accountManager.accounts.isEmpty {
            MenuItem(title: "Log In…") {
                openLoginWindow()
            }
        } else {
            MenuSectionHeader(title: "Account")
            MenuSubmenuItem(
                id: "accounts",
                title: accountTitle,
                isLoading: activity.switchingAccountId != nil || activity.isLoggingOut,
                controller: submenus
            ) {
                AccountsSubmenu(
                    authManager: authManager,
                    accountManager: accountManager,
                    tunnelManager: tunnelManager,
                    activity: activity,
                    addAccount: { openLoginWindow() },
                    manageAccounts: { openPreferencesWindow(section: .accounts) },
                    logOut: {
                        dismissMenu()
                        activity.logOut()
                    })
            }
        }
    }

    private var showsOrganizationSection: Bool {
        authManager.isAuthenticated && !isLoggedOut
    }

    private var organizationTitle: String {
        if let currentOrg = authManager.currentOrg {
            return currentOrg.name
        }
        return activity.switchingAccountId != nil ? "Loading…" : "Select Organization"
    }

    @ViewBuilder
    private var organizationSection: some View {
        MenuSectionHeader(title: "Organization")
        MenuSubmenuItem(
            id: "organizations",
            title: organizationTitle,
            isLoading: activity.switchingOrgId != nil,
            controller: submenus
        ) {
            OrganizationsSubmenu(
                authManager: authManager,
                tunnelManager: tunnelManager,
                activity: activity)
        }
        if showsExitNodeRow {
            MenuSectionHeader(title: "Exit Node")
            exitNodeRow
        }
    }

    // MARK: - Exit node

    private static let exitNodeSubmenuID = "exitNode"

    // Also true when there's an active selection but the display-name list hasn't loaded
    // yet (e.g. right after opening the menu), so the row doesn't disappear only to
    // reappear once refreshExitNodes() finishes.
    private var showsExitNodeRow: Bool {
        !authManager.sessionExpired
            && (!tunnelManager.availableExitNodes.isEmpty || tunnelManager.activeExitNodeId != nil)
    }

    private var exitNodeTitle: String {
        guard let activeId = tunnelManager.activeExitNodeId else {
            return "None"
        }
        // The name list may not have loaded yet even though the selection itself is
        // already known - show a placeholder rather than "None" so an active exit
        // node never reads as off while its name is still loading.
        let name = tunnelManager.availableExitNodes.first(where: { $0.siteResourceId == activeId })?.name
        return name ?? "…"
    }

    private var exitNodeRow: some View {
        MenuSubmenuItem(
            id: Self.exitNodeSubmenuID,
            title: exitNodeTitle,
            controller: submenus
        ) {
            ExitNodeSubmenu(tunnelManager: tunnelManager)
        }
    }

    // MARK: - Footer

    private var licenseNotices: [String] {
        guard let serverInfo = authManager.serverInfo else { return [] }
        var notices: [String] = []
        if serverInfo.build == "enterprise" {
            if let licenseType = serverInfo.enterpriseLicenseType,
                licenseType.lowercased() == "personal"
            {
                notices.append("Licensed for personal use only.")
            }
            if !serverInfo.enterpriseLicenseValid {
                notices.append("This server is unlicensed.")
            }
        }
        if serverInfo.build == "oss", !serverInfo.supporterStatusValid {
            notices.append("Community Edition. Consider supporting.")
        }
        return notices
    }

    // MARK: - Actions

    /// Closes the menu. Everything except the tunnel toggle and account or
    /// organization switches does this, so those stay visible while they load.
    private func dismissMenu() {
        submenus.close()
        MenuBarExtraDismissal.dismiss()
    }

    private func openOnboardingWindow() {
        dismissMenu()
        onboardingViewModel.hasOpenedOnboardingWindowThisSession = true
        openWindow(id: "onboarding")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApplication.shared.windows.first { $0.title == "Pangolin Setup" }?.makeKeyAndOrderFront(nil)
        }
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
            await tunnelManager.refreshExitNodes()
        }
    }


    private func openURL(_ urlString: String) {
        dismissMenu()
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens Preferences on Accounts with the login sheet. `renewing` logs in to
    /// that server right away, for a locked account.
    private func openLoginWindow(renewing hostname: String? = nil) {
        PreferencesNavigation.shared.requestedLogin = AccountLoginRequest(hostname: hostname)
        openPreferencesWindow(section: .accounts)
    }

    private func openPreferencesWindow(section: PreferencesSection? = nil) {
        if let section {
            PreferencesNavigation.shared.requestedSection = section
        }
        // A new window only gets its identifier once PreferencesWindow configures
        // it, and its title follows the selected section, so match on either.
        let titles = Set(["Preferences"] + PreferencesSection.allCases.map(\.rawValue))
        presentWindow(
            id: "preferences",
            matches: { $0.identifier?.rawValue == "preferences" || titles.contains($0.title) })
    }

    /// Opens or raises one of the app's windows and makes it key.
    private func presentWindow(
        id: String,
        matches: @escaping (NSWindow) -> Bool,
        configure: ((NSWindow) -> Void)? = nil
    ) {
        dismissMenu()

        // Show app in dock. Switching policy after activating can drop focus,
        // so do it first.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }

        let existing = NSApp.windows.filter(matches)
        if let window = existing.first {
            existing.dropFirst().forEach { $0.close() }
            configure?(window)
        } else {
            openWindow(id: id)
        }

        // Closing the menu hands focus back to the previous app, and SwiftUI
        // creates new windows a moment later, so focus again once both settle.
        for delay in [0.05, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = NSApp.windows.first(where: matches) else { return }
                guard !(NSApp.isActive && window.isKeyWindow) else { return }
                configure?(window)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }
}

/// The tunnel states the status line distinguishes. Every in-between state on
/// the way up reads as registering, and on the way down as disconnecting, so a
/// change doesn't cycle through several labels.
private enum TunnelDisplayState: Equatable {
    case disconnected(onDemand: Bool)
    case locked
    case registering
    case connected(onDemand: Bool)
    case disconnecting

    var text: String {
        switch self {
        case .disconnected(let onDemand): return onDemand ? "Disconnected · On-Demand" : "Disconnected"
        case .locked: return "Account Locked"
        case .registering: return "Registering…"
        case .connected(let onDemand): return onDemand ? "Connected · On-Demand" : "Connected"
        case .disconnecting: return "Disconnecting…"
        }
    }

    /// Same colors as the iOS status card.
    var color: Color {
        switch self {
        case .connected: return .green
        case .registering: return .orange
        case .disconnected(onDemand: true): return Color(nsColor: .systemYellow)
        case .disconnecting, .disconnected(onDemand: false), .locked: return Color.secondary.opacity(0.5)
        }
    }

    /// Yellow while on-demand is engaged but its rules keep the tunnel down,
    /// as on iOS. Otherwise the switch uses the system accent.
    var toggleTint: Color? {
        self == .disconnected(onDemand: true) ? Color(nsColor: .systemYellow) : nil
    }

    var isTransitioning: Bool {
        self == .registering || self == .disconnecting
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// Not connected and not on the way there.
    var isIdle: Bool {
        switch self {
        case .disconnected, .locked: return true
        case .registering, .connected, .disconnecting: return false
        }
    }
}

// MARK: - Submenus

struct AccountsSubmenu: View {
    @ObservedObject var authManager: AuthManager
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var tunnelManager: TunnelManager
    @ObservedObject var activity: MenuBarActivity
    let addAccount: () -> Void
    let manageAccounts: () -> Void
    let logOut: () -> Void

    /// Sorted so the list doesn't reshuffle between openings.
    private var accounts: [Account] {
        accountManager.accounts.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func label(for account: Account) -> String {
        // If multiple accounts share the same email, show hostname to differentiate
        let sharesEmail = accounts.filter { $0.email == account.email }.count > 1
        return sharesEmail ? "\(account.displayName) (\(account.hostname))" : account.displayName
    }

    var body: some View {
        MenuSectionHeader(title: "Available Accounts", inset: true)
        ForEach(accounts, id: \.userId) { account in
            MenuItem(
                title: label(for: account),
                showsCheckColumn: true,
                isChecked: accountManager.activeAccount?.userId == account.userId,
                isLoading: activity.switchingAccountId == account.userId
            ) {
                activity.switchAccount(to: account)
            }
            .disabled(activity.isTunnelStarting || activity.isSwitching)
        }

        MenuSeparator()

        MenuItem(title: "Add Account…", showsCheckColumn: true) {
            addAccount()
        }
        .disabled(activity.isSwitching)

        MenuItem(title: "Manage Accounts…", showsCheckColumn: true) {
            manageAccounts()
        }

        if accountManager.activeAccount != nil {
            MenuItem(title: "Log Out", showsCheckColumn: true, isLoading: activity.isLoggingOut) {
                logOut()
            }
            .disabled(activity.isSwitching)
        }
    }
}

struct OrganizationsSubmenu: View {
    @ObservedObject var authManager: AuthManager
    @ObservedObject var tunnelManager: TunnelManager
    @ObservedObject var activity: MenuBarActivity

    private var organizations: [Organization] {
        authManager.organizations
    }

    var body: some View {
        if organizations.isEmpty {
            MenuLabel(
                text: activity.switchingAccountId != nil ? "Loading…" : "No Organizations")
        } else {
            MenuSectionHeader(
                title: organizations.count == 1 ? "1 Organization" : "\(organizations.count) Organizations",
                inset: true)
            ForEach(organizations, id: \.orgId) { org in
                MenuItem(
                    title: org.name,
                    showsCheckColumn: true,
                    isChecked: authManager.currentOrg?.orgId == org.orgId,
                    isLoading: activity.switchingOrgId == org.orgId
                ) {
                    activity.selectOrganization(org)
                }
                .disabled(activity.isTunnelStarting || activity.isSwitching)
            }
        }
    }
}

/// Exit node selector: routes all tunnel traffic through a gateway resource. Hidden when the
/// org has no exit nodes.
struct ExitNodeSubmenu: View {
    @ObservedObject var tunnelManager: TunnelManager

    private var exitNodes: [SiteResource] {
        tunnelManager.availableExitNodes
    }

    private var isDisabled: Bool {
        switch tunnelManager.status {
        case .starting, .registering:
            return true
        default:
            return false
        }
    }

    var body: some View {
        MenuSectionHeader(title: "Route All Traffic Through", inset: true)

        MenuItem(
            title: "None",
            showsCheckColumn: true,
            isChecked: tunnelManager.activeExitNodeId == nil
        ) {
            Task {
                await tunnelManager.disableExitNode()
            }
        }
        .disabled(isDisabled)

        ForEach(exitNodes) { node in
            MenuItem(
                title: node.name,
                showsCheckColumn: true,
                isChecked: tunnelManager.activeExitNodeId == node.siteResourceId
            ) {
                Task {
                    await tunnelManager.selectExitNode(node)
                }
            }
            .disabled(isDisabled)
        }
    }
}

/// Lists each site with its status. Hovering a site shows its details.
struct SitesSubmenu: View {
    @ObservedObject var olmStatusManager: OLMStatusManager
    @ObservedObject var tunnelManager: TunnelManager
    /// Opens the per-site detail submenus.
    let controller: MenuSubmenuController
    let openStatusPanel: () -> Void

    private var sites: [SiteStatusItem] {
        guard let status = olmStatusManager.socketStatus else { return [] }
        return SiteStatusItem.list(from: status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rows
        }
        // Poll only while the list is on screen.
        .onAppear { olmStatusManager.startPolling() }
        .onDisappear { olmStatusManager.stopPolling() }
    }

    @ViewBuilder
    private var rows: some View {
        MenuItem(title: "Open Status…") {
            openStatusPanel()
        }

        MenuSeparator()

        if !sites.isEmpty {
            MenuSectionHeader(title: sites.count == 1 ? "1 Site" : "\(sites.count) Sites")
            ForEach(sites) { site in
                MenuSubmenuItem(
                    id: site.id,
                    title: site.name,
                    dotColor: site.connected ? .green : Color.secondary.opacity(0.5),
                    controller: controller
                ) {
                    SiteDetailSubmenu(siteID: site.id, olmStatusManager: olmStatusManager)
                }
            }
        } else if olmStatusManager.socketStatus == nil && !tunnelManager.isNEConnected {
            MenuLabel(text: "Connect to see sites.")
        } else if olmStatusManager.socketStatus == nil {
            MenuLabel(text: "Loading…")
        } else {
            MenuLabel(text: "No sites")
        }
    }
}

/// Details for one site, kept live by the sites submenu's polling.
struct SiteDetailSubmenu: View {
    let siteID: String
    @ObservedObject var olmStatusManager: OLMStatusManager

    private var site: SiteStatusItem? {
        guard let status = olmStatusManager.socketStatus else { return nil }
        return SiteStatusItem.list(from: status).first { $0.id == siteID }
    }

    var body: some View {
        if let site {
            MenuSectionHeader(title: site.name)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("Status")
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Circle()
                        .fill(site.connected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text(site.connected ? "Connected" : "Disconnected")
                        .foregroundStyle(.secondary)
                }
            }
            .font(MenuMetrics.font)
            .padding(.horizontal, MenuMetrics.rowHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: MenuMetrics.rowHeight, alignment: .leading)
            MenuDetailRow(label: "Connection", value: site.connection ?? "—")
            MenuDetailRow(label: "Exit Node", value: site.connection != nil ? (site.isGateway ? "Yes" : "No") : "—")
            MenuDetailRow(label: "Endpoint", value: Self.display(site.endpoint))
            MenuDetailRow(label: "Last Seen", value: site.lastSeenDescription)
        } else {
            MenuLabel(text: "This site is no longer connected.")
        }
    }

    private static func display(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }
}

struct MoreSubmenu: View {
    @ObservedObject var checkForUpdatesViewModel: CheckForUpdatesViewModel
    let openURL: (String) -> Void
    let checkForUpdates: () -> Void

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    var body: some View {
        MenuSectionHeader(title: "Support")
        MenuItem(title: "How Pangolin Works") {
            openURL("https://docs.pangolin.net/about/how-pangolin-works")
        }
        MenuItem(title: "Documentation") {
            openURL("https://docs.pangolin.net/")
        }

        MenuSeparator()

        MenuSectionHeader(title: "© \(String(Calendar.current.component(.year, from: Date()))) Fossorial, Inc.")
        MenuItem(title: "Terms of Service") {
            openURL("https://pangolin.net/tos")
        }
        MenuItem(title: "Privacy Policy") {
            openURL("https://pangolin.net/privacy")
        }

        MenuSeparator()

        MenuSectionHeader(title: "Version \(appVersion)")
        MenuItem(title: "Check for Updates…") {
            checkForUpdates()
        }
        .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}
