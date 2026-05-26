import AppKit
import Combine
import Sparkle
import SwiftUI

extension Notification.Name {
    /// Fired by any UI code that wants to open a managed window (login, onboarding,
    /// preferences). The AppDelegate observes this and routes to AppWindowsController,
    /// which creates/raises the corresponding NSWindow. We use a notification rather
    /// than calling AppWindowsController directly so that callers don't need a
    /// reference to it (and so the same code path works regardless of where the
    /// caller lives in the view hierarchy).
    static let pangolinOpenWindow = Notification.Name("pangolinOpenWindow")
}

/// Posts the `pangolinOpenWindow` notification with the given window id.
@MainActor
func postOpenWindow(id: String) {
    NotificationCenter.default.post(
        name: .pangolinOpenWindow, object: nil, userInfo: ["id": id]
    )
}

// MARK: - ResourceCache (long-lived store with background polling)

@MainActor
final class ResourceCache: ObservableObject {
    @Published private(set) var publicResources: [UserResource] = []
    @Published private(set) var siteResources: [UserSiteResource] = []
    @Published private(set) var siteResourceDetails: [Int: SiteResourceDetail] = [:]
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastFetched: Date?
    @Published private(set) var lastError: String?

    weak var apiClient: APIClient?
    weak var authManager: AuthManager?
    weak var tunnelManager: TunnelManager?

    private var pollingTimer: Timer?
    private let pollingInterval: TimeInterval = 180  // 3 minutes

    /// Monotonic counter for the current refresh. Each refresh() call bumps this
    /// and captures its value as a token; after every `await` the token is checked
    /// against the latest, and stale results are discarded. Prevents an older
    /// in-flight refresh from overwriting a newer one's results.
    private var refreshSequence: Int = 0

    /// Starts the polling timer (or resets it if already running). Each call
    /// re-arms the timer so the next tick is `pollingInterval` from now.
    func startPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(
            withTimeInterval: pollingInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshIfConnected()
            }
        }
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    /// Refresh only when the tunnel is connected — otherwise we'd just be hammering
    /// the server with requests that produce 0 results from the user's perspective.
    func refreshIfConnected() async {
        guard tunnelManager?.status == .connected else { return }
        await refresh()
    }

    func refresh() async {
        guard let apiClient = apiClient,
              let authManager = authManager,
              let orgId = authManager.currentOrg?.orgId else { return }

        refreshSequence &+= 1
        let token = refreshSequence
        isLoading = true
        lastError = nil

        do {
            let result = try await apiClient.listUserResources(orgId: orgId)
            // Discard if a newer refresh has started while we were awaiting.
            guard token == refreshSequence else { return }
            publicResources = result.resources
            siteResources = result.siteResources

            if !siteResources.isEmpty,
               let details = try? await apiClient.listAllSiteResources(orgId: orgId) {
                guard token == refreshSequence else { return }
                siteResourceDetails = Dictionary(
                    uniqueKeysWithValues: details.map { ($0.siteResourceId, $0) }
                )
            } else {
                guard token == refreshSequence else { return }
                siteResourceDetails = [:]
            }
            lastFetched = Date()
        } catch {
            guard token == refreshSequence else { return }
            lastError = "Failed to load resources"
        }

        // Only the latest refresh clears the loading state and re-arms the timer.
        guard token == refreshSequence else { return }
        isLoading = false
        // Re-arm the polling timer so the next automatic fetch is `pollingInterval`
        // from this refresh, regardless of whether it was triggered by the timer
        // itself, the menu opening, or a manual Refresh click.
        if pollingTimer != nil {
            startPolling()
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var apiClient: APIClient
    @ObservedObject var authManager: AuthManager
    @ObservedObject var tunnelManager: TunnelManager
    let updater: SPUUpdater
    @ObservedObject var onboardingViewModel: MacOnboardingViewModel
    @ObservedObject var resourceCache: ResourceCache
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    @State private var menuOpenCount = 0
    @State private var isLoggedOut = false

    // In-popover navigation state.
    @State private var publicSearch: String = ""
    @State private var privateSearch: String = ""
    @State private var selectedResourceDetail: ResourceListItem?
    @State private var detailPopoverHovered: Bool = false
    @State private var submenuPanelHovered: Bool = false
    @State private var rowAnchorFrames: [String: NSRect] = [:]
    @FocusState private var searchFocused: Bool
    @StateObject private var submenuCoordinator = SubmenuCoordinator()
    @StateObject private var detailPanel = MenuPanelController()
    @StateObject private var submenuPanel = MenuPanelController()

    // Read-only proxies that pull from the long-lived ResourceCache so background
    // polling updates flow into the UI automatically.
    private var publicResources: [UserResource] { resourceCache.publicResources }
    private var siteResources: [UserSiteResource] { resourceCache.siteResources }
    private var siteResourceDetails: [Int: SiteResourceDetail] { resourceCache.siteResourceDetails }
    private var resourcesLoading: Bool { resourceCache.isLoading }
    private var resourcesError: String? { resourceCache.lastError }
    private var resourcesLastFetched: Date? { resourceCache.lastFetched }

    init(
        configManager: ConfigManager,
        accountManager: AccountManager,
        apiClient: APIClient,
        authManager: AuthManager,
        tunnelManager: TunnelManager,
        updater: SPUUpdater,
        onboardingViewModel: MacOnboardingViewModel,
        resourceCache: ResourceCache,
    ) {
        self.configManager = configManager
        self.accountManager = accountManager
        self.apiClient = apiClient
        self.authManager = authManager
        self.tunnelManager = tunnelManager
        self.updater = updater
        self.onboardingViewModel = onboardingViewModel
        self.resourceCache = resourceCache
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        mainContent
            .frame(width: 240)
            .onChange(of: selectedResourceDetail?.id) {
                handleDetailChange()
            }
            .onChange(of: submenuCoordinator.openId) {
                if submenuCoordinator.openId == nil {
                    submenuPanel.hide()
                }
            }
            .onDisappear {
                // 1-depth (MenuBarExtra .window popover) dismissed — close all child panels.
                submenuCoordinator.openId = nil
                selectedResourceDetail = nil
                submenuPanel.hide()
                detailPanel.hide()
            }
    }

    @MainActor
    private func handleDetailChange() {
        if let item = selectedResourceDetail {
            showDetailPanel(for: item)
        } else {
            detailPanel.hide()
        }
    }

    @MainActor
    private func showDetailPanel(for item: ResourceListItem) {
        // Anchor: prefer the parent submenu panel's right edge + mouse Y. This avoids
        // stale AnchorReader frames when the user scrolls inside the 2-depth list.
        let anchor: NSRect
        if let panelFrame = submenuPanel.currentFrame, submenuPanel.isVisible {
            let mouseY = NSEvent.mouseLocation.y
            anchor = NSRect(
                x: panelFrame.maxX - 4,
                y: mouseY - 1,
                width: 1,
                height: 1
            )
        } else if let cached = rowAnchorFrames[item.id] {
            anchor = cached
        } else {
            return
        }
        detailPanel.show(
            anchor: anchor,
            onClickOutside: { [self] in
                selectedResourceDetail = nil
            }
        ) {
            resourceDetailContent(item: item)
                .onHover { hovering in
                    detailPopoverHovered = hovering
                }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            if onboardingViewModel.isPresenting {
                // Minimal menu during onboarding: just the launcher and Quit. Hiding
                // the rest avoids inviting interactions (resources, accounts, etc.)
                // while the user still has system-extension/VPN setup to complete.
                onboardingMenuContent
            } else {
                fullMenuContent
            }
        }
        // Vertical padding keeps the first/last row's hover-highlight rectangle
        // out of the panel's rounded-corner curve, so the corner doesn't clip
        // into the highlight (which made the corners look "chipped").
        .padding(.vertical, 6)
        .task {
            await onboardingViewModel.refreshPages()
            if onboardingViewModel.isPresenting, !onboardingViewModel.hasOpenedOnboardingWindowThisSession {
                onboardingViewModel.hasOpenedOnboardingWindowThisSession = true
                postOpenWindow(id: "onboarding")
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
        .onChange(of: authManager.isAuthenticated) { oldValue, newValue in
            // Reset logged out state when authentication state changes
            if newValue {
                isLoggedOut = false
            }
        }
    }

    @ViewBuilder
    private var onboardingMenuContent: some View {
        MenuItemTextRow(title: "Open Pangolin Setup") {
            postOpenWindow(id: "onboarding")
        }
        MenuItemDivider()
        quitRow
    }

    @ViewBuilder
    private var quitRow: some View {
        MenuItemRow(action: {
            Task {
                await tunnelManager.disconnect()
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run {
                    NSApplication.shared.terminate(nil)
                }
            }
        }, label: {
            HStack {
                Text("Quit")
                Spacer()
                Text("⌘Q")
                    .font(.caption)
                    .opacity(0.6)
            }
        })
    }

    @ViewBuilder
    private var fullMenuContent: some View {
        Group {
            if authManager.isInitializing {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Loading...").foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if authManager.isServerDown {
                    MenuItemInfoRow(title: "The server appears to be down.")
                    MenuItemDivider()
                }

                if let errorMessage = authManager.errorMessage,
                   !authManager.isServerDown, !authManager.sessionExpired {
                    MenuItemInfoRow(title: errorMessage)
                    MenuItemDivider()
                }

                if authManager.isAuthenticated && !isLoggedOut {
                    if accountManager.activeAccount != nil {
                        if authManager.sessionExpired {
                            MenuItemInfoRow(title: "Account Locked")
                            MenuItemTextRow(
                                title: "Log In",
                                disabled: authManager.isDeviceAuthInProgress
                            ) {
                                authManager.startDeviceAuthImmediately = true
                                openLoginWindow()
                            }
                        } else {
                            ConnectToggleRow(
                                tunnelManager: tunnelManager,
                                onboardingViewModel: onboardingViewModel
                            )
                        }
                        MenuItemDivider()
                    }
                }

                if accountManager.accounts.count > 0 {
                    MenuItemSectionHeader(title: "Account")
                    HoverSubmenuRow(
                        id: "account",
                        title: activeAccountLabel(),
                        coordinator: submenuCoordinator,
                        panelController: submenuPanel,
                        submenuHoveredBinding: $submenuPanelHovered
                    ) {
                        accountsPopoverContent
                    }
                    .id(menuOpenCount)
                    .task {
                        if authManager.isAuthenticated {
                            await handleMenuOpen()
                        }
                    }
                } else {
                    MenuItemTextRow(title: "Login") { openLoginWindow() }
                }

                if authManager.isAuthenticated && !isLoggedOut {
                    MenuItemSectionHeader(title: "Organization")
                    HoverSubmenuRow(
                        id: "org",
                        title: authManager.currentOrg?.name ?? "Organizations",
                        coordinator: submenuCoordinator,
                        panelController: submenuPanel,
                        submenuHoveredBinding: $submenuPanelHovered
                    ) {
                        orgsPopoverContent
                    }
                }
            }

            if authManager.isAuthenticated && !isLoggedOut && !authManager.sessionExpired,
               authManager.currentOrg != nil {
                MenuItemDivider()
                let detailActive = (selectedResourceDetail != nil) || detailPopoverHovered
                let isConnected = tunnelManager.status == .connected
                MenuItemSectionHeader(title: "Resources")

                let publicCount = isConnected ? publicResources.filter { $0.enabled }.count : 0
                let privateCount = isConnected ? siteResources.filter { $0.enabled }.count : 0

                HoverSubmenuRow(
                    id: "public",
                    title: "Public",
                    trailing: "\(publicCount)",
                    keepOpenSignal: detailActive
                        && submenuCoordinator.openId == AnyHashable("public"),
                    coordinator: submenuCoordinator,
                    panelController: submenuPanel,
                    submenuHoveredBinding: $submenuPanelHovered
                ) {
                    ResourceListPanelView(
                        query: $publicSearch,
                        selectedDetail: $selectedResourceDetail,
                        detailPopoverHovered: $detailPopoverHovered,
                        allItems: publicResources.filter { $0.enabled }.map { .publicItem($0) },
                        detailLookup: { detail(for: $0) },
                        onOpen: { openInBrowser($0) },
                        onCopyAlias: { copyAlias(for: $0) },
                        onCopyAddress: { copyAddress(for: $0) },
                        onAnchorUpdate: { id, rect in rowAnchorFrames[id] = rect },
                        requiresConnection: true,
                        isConnected: isConnected
                    )
                }
                .onAppear {
                    Task { await loadResourcesIfNeeded() }
                }
                HoverSubmenuRow(
                    id: "private",
                    title: "Private",
                    trailing: "\(privateCount)",
                    keepOpenSignal: detailActive
                        && submenuCoordinator.openId == AnyHashable("private"),
                    coordinator: submenuCoordinator,
                    panelController: submenuPanel,
                    submenuHoveredBinding: $submenuPanelHovered
                ) {
                    ResourceListPanelView(
                        query: $privateSearch,
                        selectedDetail: $selectedResourceDetail,
                        detailPopoverHovered: $detailPopoverHovered,
                        allItems: siteResources.filter { $0.enabled }.map { .siteItem($0) },
                        detailLookup: { detail(for: $0) },
                        onOpen: { openInBrowser($0) },
                        onCopyAlias: { copyAlias(for: $0) },
                        onCopyAddress: { copyAddress(for: $0) },
                        onAnchorUpdate: { id, rect in rowAnchorFrames[id] = rect },
                        requiresConnection: true,
                        isConnected: isConnected
                    )
                }

                if isConnected {
                    ResourcesRefreshRow(
                        lastFetched: resourcesLastFetched,
                        isLoading: resourcesLoading,
                        onRefresh: {
                            Task { await loadResources() }
                        }
                    )
                }
            }

            MenuItemDivider()

            HoverSubmenuRow(
                id: "more",
                title: "More",
                coordinator: submenuCoordinator,
                panelController: submenuPanel,
                submenuHoveredBinding: $submenuPanelHovered
            ) {
                morePopoverContent
            }

            MenuItemDivider()

            if let serverInfo = authManager.serverInfo,
               serverInfo.build == "enterprise",
               let licenseType = serverInfo.enterpriseLicenseType,
               licenseType.lowercased() == "personal" {
                MenuItemInfoRow(title: "Licensed for personal use only.")
            }
            if let serverInfo = authManager.serverInfo,
               serverInfo.build == "enterprise",
               !serverInfo.enterpriseLicenseValid {
                MenuItemInfoRow(title: "This server is unlicensed.")
            }
            if let serverInfo = authManager.serverInfo,
               serverInfo.build == "oss",
               !serverInfo.supporterStatusValid {
                MenuItemInfoRow(title: "Community Edition. Consider supporting.")
            }

            quitRow
        }
    }

    private func detail(for item: ResourceListItem) -> SiteResourceDetail? {
        if case .siteItem(let r) = item {
            return siteResourceDetails[r.siteResourceId]
        }
        return nil
    }

    private func performPrimary(_ item: ResourceListItem) {
        switch item {
        case .publicItem:
            openInBrowser(item)
        case .siteItem(let r):
            if r.mode == "http" {
                openInBrowser(item)
            } else {
                copyAlias(for: item)
            }
        }
    }

    private func openInBrowser(_ item: ResourceListItem) {
        var url: URL?
        switch item {
        case .publicItem(let r):
            url = URL(string: r.domain)
        case .siteItem(let r):
            let scheme = r.ssl ? "https" : (r.scheme ?? "http")
            let host: String = r.fullDomain
                ?? (r.alias?.isEmpty == false ? r.alias : nil)
                ?? r.aliasAddress
                ?? r.destination
            if !host.isEmpty {
                url = URL(string: "\(scheme)://\(host)")
            }
        }
        if let url = url { NSWorkspace.shared.open(url) }
    }

    private func copyAlias(for item: ResourceListItem) {
        let text: String
        switch item {
        case .publicItem(let r):
            text = r.domain
        case .siteItem(let r):
            if let a = r.alias, !a.isEmpty { text = a }
            else if let aa = r.aliasAddress, !aa.isEmpty { text = aa }
            else { text = r.destination }
        }
        copyToClipboard(text)
    }

    private func copyAddress(for item: ResourceListItem) {
        let text: String
        switch item {
        case .publicItem(let r):
            text = r.domain
        case .siteItem(let r):
            if let aa = r.aliasAddress, !aa.isEmpty { text = aa }
            else { text = r.destination }
        }
        copyToClipboard(text)
    }

    @MainActor
    private func loadResourcesIfNeeded() async {
        // Refresh through the long-lived ResourceCache so background polling and
        // foreground refreshes stay coherent.
        await resourceCache.refresh()
    }

    @MainActor
    private func loadResources() async {
        await resourceCache.refresh()
    }

    // MARK: - Hover Popover Content (no BackHeader; rendered inside HoverSubmenuRow's popover)

    @ViewBuilder
    private var accountsPopoverContent: some View {
        let accounts = Array(accountManager.accounts.values)
        let currentUserId = accountManager.activeAccount?.userId
        let disable: Bool = {
            switch tunnelManager.status {
            case .starting, .registering: return true
            default: return false
            }
        }()

        VStack(spacing: 0) {
            ForEach(accounts, id: \.userId) { account in
                MenuItemRow(action: {
                    Task { await authManager.switchAccount(userId: account.userId) }
                }, label: {
                    HStack {
                        Text(formatAccountLabelExternal(account: account, accounts: accounts))
                        Spacer()
                        if currentUserId == account.userId {
                            Image(systemName: "checkmark").font(.caption)
                        }
                    }
                }, disabled: disable)
            }

            MenuItemDivider()

            MenuItemTextRow(title: "Add Account") { openLoginWindow() }

            if accountManager.activeAccount != nil {
                MenuItemTextRow(title: "Logout") {
                    Task { await authManager.logout() }
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 240)
    }

    @ViewBuilder
    private var orgsPopoverContent: some View {
        let orgs = authManager.organizations
        let currentOrgId = authManager.currentOrg?.orgId
        let disable: Bool = {
            switch tunnelManager.status {
            case .starting, .registering: return true
            default: return false
            }
        }()

        VStack(spacing: 0) {
            if orgs.isEmpty {
                MenuItemInfoRow(title: "No organizations")
            } else {
                ForEach(orgs, id: \.orgId) { org in
                    MenuItemRow(action: {
                        Task { await authManager.selectOrganization(org) }
                    }, label: {
                        HStack {
                            Text(org.name)
                            Spacer()
                            if currentOrgId == org.orgId {
                                Image(systemName: "checkmark").font(.caption)
                            }
                        }
                    }, disabled: disable)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 220)
    }

    @ViewBuilder
    private var morePopoverContent: some View {
        VStack(spacing: 0) {
            MenuItemInfoRow(title: "Support")
            MenuItemTextRow(title: "How Pangolin Works") {
                openURL("https://docs.pangolin.net/about/how-pangolin-works")
            }
            MenuItemTextRow(title: "Documentation") {
                openURL("https://docs.pangolin.net/")
            }

            MenuItemDivider()

            MenuItemInfoRow(title: "© \(String(Calendar.current.component(.year, from: Date()))) Fossorial, Inc.")
            MenuItemTextRow(title: "Terms of Service") {
                openURL("https://pangolin.net/terms-of-service.html")
            }
            MenuItemTextRow(title: "Privacy Policy") {
                openURL("https://pangolin.net/privacy-policy.html")
            }

            MenuItemDivider()

            MenuItemInfoRow(title: "Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")")
            MenuItemTextRow(
                title: "Check for Updates",
                disabled: !checkForUpdatesViewModel.canCheckForUpdates
            ) {
                updater.checkForUpdates()
            }
            MenuItemTextRow(title: "Preferences") { openPreferencesWindow() }
        }
        .padding(.vertical, 6)
        .frame(width: 240)
    }

    @ViewBuilder
    private func resourceDetailContent(item: ResourceListItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            BackHeader(title: item.name) {
                selectedResourceDetail = nil
            }
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                detailInfoRows(for: item)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            VStack(spacing: 0) {
                if hasOpenURL(for: item) {
                    MenuItemFeedbackRow(
                        title: "Open in Browser",
                        feedbackText: "Opened"
                    ) {
                        openInBrowser(item)
                    }
                }
                if hasAlias(for: item) {
                    MenuItemFeedbackRow(
                        title: "Copy Alias",
                        feedbackText: "Copied"
                    ) {
                        copyAlias(for: item)
                    }
                }
                MenuItemFeedbackRow(
                    title: addressActionTitle(for: item),
                    feedbackText: "Copied"
                ) {
                    copyAddress(for: item)
                }
            }
            .padding(.bottom, 4)
        }
        .frame(width: 260)
    }

    @ViewBuilder
    private func detailInfoRows(for item: ResourceListItem) -> some View {
        switch item {
        case .publicItem(let r):
            DetailInfoRow(label: "Domain", value: r.domain)
            DetailInfoRow(label: "Protocol", value: r.resourceProtocol)
            if r.isProtected {
                DetailInfoRow(label: "Protected", value: "Yes")
            }
        case .siteItem(let r):
            switch r.mode {
            case "http":
                if let domain = r.fullDomain, !domain.isEmpty {
                    DetailInfoRow(label: "Domain", value: domain)
                }
                DetailInfoRow(label: "Destination", value: r.destination)
            case "cidr":
                DetailInfoRow(label: "CIDR", value: r.destination)
            default:
                DetailInfoRow(label: "Address", value: r.destination)
            }
            if let alias = r.alias, !alias.isEmpty {
                DetailInfoRow(label: "Alias", value: alias)
            }
            if let aliasAddr = r.aliasAddress, !aliasAddr.isEmpty, aliasAddr != r.alias {
                DetailInfoRow(label: "Alias IP", value: aliasAddr)
            }
            DetailInfoRow(label: "Mode", value: r.mode.uppercased())
            if let d = siteResourceDetails[r.siteResourceId] {
                if let names = d.siteNames, !names.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Site")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Circle()
                            .fill(d.primarySiteOnline ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(names.joined(separator: ", "))
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
                // Always show TCP / UDP / ICMP rows so the user can see at a glance
                // which protocols are open, blocked, or unrestricted on the resource.
                DetailInfoRow(label: "TCP", value: portValue(d.tcpPortRangeString))
                DetailInfoRow(label: "UDP", value: portValue(d.udpPortRangeString))
                DetailInfoRow(
                    label: "ICMP",
                    value: (d.disableIcmp == false) ? "enabled" : "disabled"
                )
            }
        }
    }

    /// Formats a port range string for display. Server uses "*" to mean
    /// "all ports" and an empty / nil string to mean "no ports allowed".
    private func portValue(_ raw: String?) -> String {
        guard let raw = raw, !raw.isEmpty else { return "—" }
        return raw == "*" ? "all" : raw
    }

    private func hasOpenURL(for item: ResourceListItem) -> Bool {
        switch item {
        case .publicItem: return true
        case .siteItem(let r): return r.mode == "http"
        }
    }

    private func hasAlias(for item: ResourceListItem) -> Bool {
        if case .siteItem(let r) = item {
            return (r.alias?.isEmpty == false)
        }
        return false
    }

    private func addressActionTitle(for item: ResourceListItem) -> String {
        switch item {
        case .publicItem: return "Copy URL"
        case .siteItem(let r):
            return r.mode == "cidr" ? "Copy CIDR" : "Copy Address"
        }
    }

    // MARK: - Account label helpers

    private func activeAccountLabel() -> String {
        guard let active = accountManager.activeAccount else { return "Account" }
        let accounts = Array(accountManager.accounts.values)
        return formatAccountLabelExternal(account: active, accounts: accounts)
    }

    private func formatAccountLabelExternal(account: Account, accounts: [Account]) -> String {
        // Show email; if duplicates, append hostname for clarity.
        let emailCount = accounts.filter { $0.email == account.email }.count
        if emailCount > 1 {
            let host = URL(string: account.hostname)?.host ?? account.hostname
            return "\(account.email) (\(host))"
        }
        return account.email
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
        postOpenWindow(id: "main")
    }

    private func openPreferencesWindow() {
        postOpenWindow(id: "preferences")
    }
}

/// Custom switch that doesn't dim when its parent window loses key (unlike the
/// system NSSwitch used by SwiftUI Toggle.toggleStyle(.switch)).
struct CustomSwitch: View {
    @Binding var isOn: Bool
    var disabled: Bool = false
    let action: () -> Void

    private let trackWidth: CGFloat = 30
    private let trackHeight: CGFloat = 18
    private let knobSize: CGFloat = 14

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: trackHeight / 2)
                .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: trackWidth, height: trackHeight)
            Circle()
                .fill(Color.white)
                .frame(width: knobSize, height: knobSize)
                .padding(.horizontal, (trackHeight - knobSize) / 2)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
        }
        .frame(width: trackWidth, height: trackHeight)
        .opacity(disabled ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.15), value: isOn)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !disabled else { return }
            action()
        }
    }
}

/// Status row with a Toggle switch for Connect/Disconnect.
struct ConnectToggleRow: View {
    @ObservedObject var tunnelManager: TunnelManager
    @ObservedObject var onboardingViewModel: MacOnboardingViewModel

    private var statusColor: Color {
        switch tunnelManager.status {
        case .connected: return .green
        case .starting, .registering: return .orange
        default: return .secondary
        }
    }

    private func performToggle() {
        Task { @MainActor in
            if !tunnelManager.isNEConnected {
                await onboardingViewModel.refreshPages()
                if onboardingViewModel.isPresenting {
                    onboardingViewModel.hasOpenedOnboardingWindowThisSession = true
                    postOpenWindow(id: "onboarding")
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

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(tunnelManager.status.displayText)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            CustomSwitch(
                isOn: .constant(tunnelManager.isNEConnected),
                disabled: tunnelManager.status == .starting,
                action: performToggle
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

@MainActor
func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

// MARK: - AppKit-backed detail panel
//
// SwiftUI's `.popover` uses NSPopover with `.transient` behavior, which auto-dismisses on
// any click — including clicks inside nested popovers. To get reliable click handling and
// a flat (non-bubble) appearance, the resource detail is shown via a borderless NSPanel
// hosted manually.

/// Reads the on-screen frame of the SwiftUI view it is attached to. Used to anchor an
/// NSPanel near a SwiftUI row.
struct AnchorReader: NSViewRepresentable {
    var onFrame: (NSRect) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        view.onFrameChange = onFrame
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let view = nsView as? AnchorView
        view?.onFrameChange = onFrame
        // SwiftUI re-runs body when state changes (e.g. logout shrinks the menu).
        // The NSView is reused but its origin may have shifted because rows above
        // disappeared. Re-report on every update so the parent's `anchorFrame`
        // never sticks to a stale (pre-state-change) position.
        DispatchQueue.main.async { [weak view] in view?.report() }
    }

    final class AnchorView: NSView {
        var onFrameChange: ((NSRect) -> Void)?

        // Pass-through hit testing so this invisible view never intercepts mouse
        // events (e.g. .onHover modifiers on the SwiftUI parent).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            report()
        }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            super.resizeSubviews(withOldSize: oldSize)
            report()
        }

        // Catch position-only changes — e.g. when logging out shortens the menu,
        // rows above shrink/disappear and this view's origin shifts upward without
        // its size changing. None of the resize-/move-to-window hooks above fire
        // for that, so anchor frames stale and submenus opened post-logout would
        // align to the pre-logout row position. setFrameOrigin/setFrameSize fire
        // on every layout pass that touches this view.
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            report()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            report()
        }

        fileprivate func report() {
            guard let window = self.window else { return }
            let inWindow = self.convert(self.bounds, to: nil)
            let inScreen = window.convertToScreen(inWindow)
            onFrameChange?(inScreen)
        }
    }
}

/// NSHostingView subclass that accepts first mouse — important for non-activating
/// NSPanels where SwiftUI gestures otherwise refuse to fire because the window isn't key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// NSHostingController that uses FirstMouseHostingView so taps fire even in non-key panels.
final class FirstMouseHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = FirstMouseHostingView(rootView: rootView)
    }
}

/// NSPanel subclass with a flag controlling whether it can become key window.
/// Panels that contain TextFields (search) need this; panels with only buttons should not,
/// otherwise they steal keyboard focus from sibling panels (e.g. detail panel stealing
/// focus from search panel).
final class FocusableMenuPanel: NSPanel {
    /// Whether to call makeKey() on show. Submenu panels with text input do this so the
    /// search field is immediately focused. Other panels (e.g. detail) don't, but they
    /// can still become key on mouseDown via sendEvent override below — necessary because
    /// SwiftUI gesture dispatch only works in key windows.
    var allowKey: Bool = true
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown && !isKeyWindow {
            // Make key on first click so SwiftUI Buttons / DragGesture fire.
            makeKey()
        }
        super.sendEvent(event)
    }
}

/// Controller for a single floating menu panel (NSPanel) anchored next to a SwiftUI row.
/// Reusable for both 2-depth submenus (Account/Org/Public/Private/More) and 3-depth detail.
@MainActor
final class MenuPanelController: ObservableObject {
    private var panel: NSPanel?
    private var hostingController: FirstMouseHostingController<AnyView>?
    private var clickMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var hideTimer: Timer?

    var currentFrame: NSRect? { panel?.frame }
    var isVisible: Bool { panel?.isVisible == true }

    deinit {
        // Defense-in-depth cleanup. Normal path is `hide()` from MenuBarView.onDisappear;
        // this catches any other dealloc path. Avoid main actor isolation issues by
        // releasing directly (these resources don't require main-thread cleanup).
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseMoveMonitor { NSEvent.removeMonitor(m) }
        hideTimer?.invalidate()
        panel?.orderOut(nil)
    }

    func show<Content: View>(
        anchor: NSRect,
        onClickOutside: @escaping () -> Void,
        requiresKeyboard: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        let wrapped = AnyView(
            content()
                .padding(0)
                .background(MenuPanelVisualEffectBackground())
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
                )
                .compositingGroup()
        )

        if hostingController == nil {
            hostingController = FirstMouseHostingController(rootView: wrapped)
        } else {
            hostingController?.rootView = wrapped
        }
        guard let host = hostingController else { return }

        // Compute fitting size from SwiftUI content.
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize

        if panel == nil {
            let p = FocusableMenuPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: true
            )
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovable = false
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            // becomesKeyOnlyIfNeeded=true would prevent panels without text input
            // from ever becoming key — and SwiftUI gesture dispatch (onTapGesture,
            // DragGesture) only fires in key windows. So we explicitly let any panel
            // become key, controlled solely by `allowKey` / `requiresKeyboard`.
            p.becomesKeyOnlyIfNeeded = false
            p.contentViewController = host
            panel = p
        }
        guard let panel = panel as? FocusableMenuPanel else { return }
        // All panels can become key — required for SwiftUI gesture dispatch (Button taps,
        // DragGesture). The keyboard distinction now matters only for which panel
        // currently has text input focus, not for click handling.
        panel.allowKey = true

        // Position to the right of the anchor row, vertically aligned to its top.
        let panelOrigin = NSPoint(
            x: anchor.maxX + 4,
            y: anchor.maxY - size.height
        )
        panel.setFrame(NSRect(origin: panelOrigin, size: size), display: true)
        // Submenu panels (with search) immediately become key so the TextField is
        // focused. Detail panels just orderFront — key transfer happens on first
        // mouseDown via FocusableMenuPanel.sendEvent so they don't steal focus from
        // the search field while the user is just hovering rows.
        if requiresKeyboard {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }

        // Install click-outside monitor (only if not already installed).
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { _ in
                // Global monitor sees clicks OUTSIDE the app's windows. Clicks inside
                // our panel are local events (not delivered here), so they don't
                // dismiss us.
                Task { @MainActor in onClickOutside() }
            }
        }

        // Backup: if mouse stays outside ALL of our windows for a while, hide.
        // Mouse-move events only fire on movement, so we need a Timer for the case
        // where the mouse stops outside our windows.
        if mouseMoveMonitor == nil {
            mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved]
            ) { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    self.checkMouseAndScheduleHide(onOutside: onClickOutside)
                }
            }
            // Also kick off the initial check (in case mouse is already outside).
            checkMouseAndScheduleHide(onOutside: onClickOutside)
        }
    }

    /// On every mouse move (and once at install time), determine whether the cursor is
    /// inside one of our visible windows. If outside, arm a one-shot hide timer.
    /// If inside, cancel any pending hide. The timer fires regardless of further movement.
    private func checkMouseAndScheduleHide(onOutside: @escaping () -> Void) {
        let mouseLoc = NSEvent.mouseLocation
        let inside = NSApp.windows.contains { w in
            w.isVisible && w.frame.contains(mouseLoc)
        }
        if inside {
            hideTimer?.invalidate()
            hideTimer = nil
        } else if hideTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { _ in
                Task { @MainActor in onOutside() }
            }
            hideTimer = timer
        }
    }

    func hide() {
        panel?.orderOut(nil)
        // Discard the panel so the next show() recreates a fresh NSPanel.
        // Reusing the same NSPanel across show/hide cycles can leave stale
        // event-handling state (key window mishandling, etc.) that makes
        // subsequent clicks unreliable.
        panel = nil
        hostingController = nil
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
        if let m = mouseMoveMonitor {
            NSEvent.removeMonitor(m)
            mouseMoveMonitor = nil
        }
        hideTimer?.invalidate()
        hideTimer = nil
    }
}

// MARK: - macOS-style Menu Components for .window popover

/// A clickable menu row with NSMenu-like styling: full-width, left-aligned, hover highlight.
/// Uses .onTapGesture instead of Button because SwiftUI Buttons don't reliably fire
/// inside nonactivating NSPanels (events are delivered, but the button's action handler
/// isn't invoked when the window can't become key).
struct MenuItemRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    var disabled: Bool = false

    @State private var hovered: Bool = false

    var body: some View {
        label()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 26)
            .background(
                (hovered && !disabled)
                    ? Color.accentColor.opacity(0.85)
                    : Color.clear
            )
            .foregroundColor(hovered && !disabled ? .white : .primary)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            // DragGesture with minimumDistance=0 fires more reliably than .onTapGesture
            // in non-key NSPanels (where SwiftUI's normal tap dispatch is broken).
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { _ in
                        guard !disabled else { return }
                        action()
                    }
            )
    }
}

/// A simple text label menu row.
struct MenuItemTextRow: View {
    let title: String
    var trailing: String? = nil
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        MenuItemRow(action: action, label: {
            HStack {
                Text(title)
                Spacer()
                if let trailing = trailing {
                    Text(trailing).foregroundColor(.secondary)
                }
            }
        }, disabled: disabled)
    }
}

/// A menu row that briefly shows a "✓ {feedback}" message after the action runs,
/// then reverts to the normal title. Useful for Copy/Open actions where the user
/// otherwise has no visible confirmation.
struct MenuItemFeedbackRow: View {
    let title: String
    let feedbackText: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var showFeedback: Bool = false
    @State private var feedbackToken: UUID = UUID()

    var body: some View {
        MenuItemRow(action: {
            action()
            let token = UUID()
            feedbackToken = token
            withAnimation(.easeIn(duration: 0.12)) {
                showFeedback = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                if feedbackToken == token {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showFeedback = false
                    }
                }
            }
        }, label: {
            HStack(spacing: 6) {
                if showFeedback {
                    Image(systemName: "checkmark")
                        .foregroundColor(.green)
                    Text(feedbackText)
                } else {
                    Text(title)
                }
                Spacer()
            }
        }, disabled: disabled)
    }
}

/// A menu row that opens a dropdown (Menu). Styled to match menu-item look.
/// Non-clickable info text row (like a disabled/header item).
struct MenuItemInfoRow: View {
    let title: String

    var body: some View {
        Text(title)
            .foregroundColor(.secondary)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Thin divider matching menu separator style.
struct MenuItemDivider: View {
    var body: some View {
        Divider().padding(.vertical, 2)
    }
}

/// Footer row for the Resources section: shows last-fetched timestamp on the
/// left and a Refresh button on the right.
struct ResourcesRefreshRow: View {
    let lastFetched: Date?
    let isLoading: Bool
    let onRefresh: () -> Void

    @State private var hovered: Bool = false
    @State private var clockTick: Date = Date()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var timestampText: String {
        if isLoading {
            return "Refreshing..."
        }
        guard let lastFetched = lastFetched else {
            return "Never"
        }
        // Compact: today shows time-only; older shows date+time.
        if Calendar.current.isDateInToday(lastFetched) {
            return Self.timeFormatter.string(from: lastFetched)
        }
        return Self.dateFormatter.string(from: lastFetched)
    }

    private var fullTimestampTooltip: String {
        guard let lastFetched = lastFetched else { return "Never" }
        return Self.dateFormatter.string(from: lastFetched)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Updated \(timestampText)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .help(fullTimestampTooltip)
            Spacer(minLength: 4)
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(hovered ? Color.accentColor : .secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .onTapGesture {
                    guard !isLoading else { return }
                    onRefresh()
                }
                .help("Refresh resources")
        }
        .padding(.horizontal, 12)
        .padding(.top, 5)
        .padding(.bottom, 3)
    }
}

/// Small uppercase section label for grouping menu items (e.g. "Account",
/// "Resources"). Non-interactive.
struct MenuItemSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Coordinates submenu visibility so that only one HoverSubmenuRow is open at a time.
@MainActor
final class SubmenuCoordinator: ObservableObject {
    @Published var openId: AnyHashable?
}

/// A menu row that opens a submenu panel (NSPanel) on hover.
/// Coordinated via SubmenuCoordinator so opening one row replaces any other.
struct HoverSubmenuRow<Submenu: View>: View {
    let id: AnyHashable
    let title: String
    var trailing: String? = nil
    /// Optional external "keep-open" signal — used when a nested panel (e.g. resource
    /// detail) is currently active so the parent submenu stays open while the user
    /// interacts with that nested view.
    var keepOpenSignal: Bool = false
    @ObservedObject var coordinator: SubmenuCoordinator
    @ObservedObject var panelController: MenuPanelController
    @Binding var submenuHoveredBinding: Bool
    @ViewBuilder var submenu: () -> Submenu

    @State private var rowHovered: Bool = false
    @State private var hoverSession: UUID = UUID()
    @State private var anchorFrame: NSRect = .zero

    /// `submenuHoveredBinding` is shared across all HoverSubmenuRows (same panel reused).
    /// Only count it as "this row's hover" when this row is the currently-open one —
    /// otherwise other rows would think the user is hovering their own submenu and trigger
    /// an unwanted open.
    private var anyHover: Bool {
        rowHovered || (isOpen && submenuHoveredBinding) || keepOpenSignal
    }
    private var isOpen: Bool { coordinator.openId == id }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let t = trailing {
                Text(t)
                    .font(.caption)
                    .opacity(rowHovered ? 0.95 : 0.6)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .opacity(0.6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 26)
        .background(rowHovered ? Color.accentColor.opacity(0.85) : Color.clear)
        .foregroundColor(rowHovered ? .white : .primary)
        .contentShape(Rectangle())
        .background(
            AnchorReader { rect in
                // Only update the anchor for next show. DO NOT call showPanel() here:
                // any layout-triggering state change would re-fire this callback,
                // which would recreate the panel content struct and lose @FocusState
                // (causing the search field to lose keyboard focus mid-typing).
                anchorFrame = rect
            }
        )
        .onHover { hovering in
            rowHovered = hovering
            scheduleUpdate()
        }
        .onChange(of: isOpen) {
            if isOpen {
                showPanel()
            }
            // Hide is handled centrally in MenuBarView when openId becomes nil.
        }
        .onChange(of: submenuHoveredBinding) {
            scheduleUpdate()
        }
        .onChange(of: keepOpenSignal) {
            // External keep-open changed (e.g. detail panel opened/closed). Re-evaluate
            // so any pending close timer (which captured the previous keepOpenSignal)
            // is invalidated and we re-decide with the latest value.
            scheduleUpdate()
        }
    }

    private func showPanel() {
        panelController.show(
            anchor: anchorFrame,
            onClickOutside: {
                coordinator.openId = nil
            },
            requiresKeyboard: true
        ) {
            submenu()
                .onHover { hovering in
                    submenuHoveredBinding = hovering
                }
        }
    }

    private func scheduleUpdate() {
        let token = UUID()
        hoverSession = token
        let delay: TimeInterval = anyHover ? 0.25 : 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard hoverSession == token else { return }
            if anyHover {
                if coordinator.openId != id {
                    coordinator.openId = id
                }
            } else if isOpen {
                coordinator.openId = nil
            }
        }
    }
}

// MARK: - Resource list item (used by ResourceListPanelView and detail panel)

enum ResourceListItem: Identifiable, Hashable {
    case publicItem(UserResource)
    case siteItem(UserSiteResource)

    var id: String {
        switch self {
        case .publicItem(let r): return "p-\(r.resourceId)"
        case .siteItem(let r): return "s-\(r.siteResourceId)"
        }
    }

    var name: String {
        switch self {
        case .publicItem(let r): return r.name
        case .siteItem(let r): return r.name
        }
    }

    var subtitle: String {
        switch self {
        case .publicItem(let r): return r.domain
        case .siteItem(let r):
            if let alias = r.alias, !alias.isEmpty { return alias }
            if let aa = r.aliasAddress, !aa.isEmpty { return aa }
            return r.destination
        }
    }

    var iconName: String {
        switch self {
        case .publicItem(let r): return r.isProtected ? "lock.fill" : "globe"
        case .siteItem: return "lock.fill"
        }
    }

    func matches(query: String) -> Bool {
        let q = query.lowercased()
        switch self {
        case .publicItem(let r):
            return r.name.lowercased().contains(q)
                || r.domain.lowercased().contains(q)
        case .siteItem(let r):
            if r.name.lowercased().contains(q) { return true }
            if r.destination.lowercased().contains(q) { return true }
            if let v = r.alias?.lowercased(), v.contains(q) { return true }
            if let v = r.aliasAddress?.lowercased(), v.contains(q) { return true }
            if let v = r.fullDomain?.lowercased(), v.contains(q) { return true }
            return false
        }
    }
}

struct BackHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// Self-contained panel content for Public/Private resource list with search.
/// Lives inside an NSHostingController; uses @Binding so SwiftUI re-renders the panel
/// content when the search query updates (instead of snapshotting once).
struct ResourceListPanelView: View {
    @Binding var query: String
    @Binding var selectedDetail: ResourceListItem?
    @Binding var detailPopoverHovered: Bool
    let allItems: [ResourceListItem]
    let detailLookup: (ResourceListItem) -> SiteResourceDetail?
    let onOpen: (ResourceListItem) -> Void
    let onCopyAlias: (ResourceListItem) -> Void
    let onCopyAddress: (ResourceListItem) -> Void
    let onAnchorUpdate: (String, NSRect) -> Void
    /// When false, show a "Please connect to Pangolin" notice instead of the list.
    var requiresConnection: Bool = false
    var isConnected: Bool = true

    @FocusState private var searchFocused: Bool

    private struct SiteGroup: Identifiable {
        let id: String   // site name (or "Other")
        let online: Bool
        let items: [ResourceListItem]
    }

    /// Returns true when this list contains only Site (Private) items, in which case
    /// we group by site name. Public lists stay flat.
    private func shouldGroupBySite(_ items: [ResourceListItem]) -> Bool {
        guard !items.isEmpty else { return false }
        return items.allSatisfy {
            if case .siteItem = $0 { return true } else { return false }
        }
    }

    private func makeSiteGroups(from items: [ResourceListItem]) -> [SiteGroup] {
        var order: [String] = []
        var byKey: [String: (online: Bool, items: [ResourceListItem])] = [:]

        for item in items {
            var key = "Other"
            var online = false
            if case .siteItem = item, let detail = detailLookup(item) {
                if let name = detail.primarySiteName, !name.isEmpty {
                    key = name
                    online = detail.primarySiteOnline
                }
            }
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = (online, [])
            }
            byKey[key]?.items.append(item)
            if online {
                byKey[key]?.online = true
            }
        }

        return order.map { key in
            let entry = byKey[key]!
            return SiteGroup(id: key, online: entry.online, items: entry.items)
        }
    }

    var body: some View {
        if requiresConnection && !isConnected {
            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                Text("Connect to Pangolin")
                    .font(.system(size: 13, weight: .semibold))
                Text("These resources are only accessible through a connected client.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(width: 280)
        } else {
            mainListBody
        }
    }

    @ViewBuilder
    private var mainListBody: some View {
        // `filtered` is computed inside body so it re-evaluates whenever @Binding
        // `query` changes (which is the whole point of using a struct here).
        let filtered: [ResourceListItem] = query.isEmpty
            ? allItems
            : allItems.filter { $0.matches(query: query) }
        let groupBySite = shouldGroupBySite(filtered)
        let groups: [SiteGroup] = groupBySite ? makeSiteGroups(from: filtered) : []

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search Resources...", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(6)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)

            HStack {
                Text(query.isEmpty
                     ? "\(allItems.count) Resource\(allItems.count == 1 ? "" : "s")"
                     : "\(filtered.count) of \(allItems.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

            Divider()

            if filtered.isEmpty {
                Text(query.isEmpty ? "No resources" : "No matches")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if groupBySite {
                            ForEach(groups) { group in
                                Section(header: SiteSectionHeader(
                                    name: group.id,
                                    online: group.online,
                                    count: group.items.count
                                )) {
                                    ForEach(group.items) { item in
                                        rowView(for: item)
                                    }
                                }
                            }
                        } else {
                            ForEach(filtered) { item in
                                rowView(for: item)
                            }
                        }
                    }
                }
                .frame(height: 380)
            }
        }
        .frame(width: 280)
        .padding(.bottom, 4)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                searchFocused = true
            }
        }
    }

    @ViewBuilder
    private func rowView(for item: ResourceListItem) -> some View {
        ResourceRow(
            item: item,
            onOpen: { onOpen(item) },
            onCopyAlias: { onCopyAlias(item) },
            onCopyAddress: { onCopyAddress(item) },
            selectedDetail: $selectedDetail,
            detailPopoverHovered: $detailPopoverHovered
        )
        .background(
            AnchorReader { rect in
                onAnchorUpdate(item.id, rect)
            }
        )
        Divider().opacity(0.25)
    }
}

struct SiteSectionHeader: View {
    let name: String
    let online: Bool
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(online ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        // Opaque background so pinned headers don't bleed through underlying rows
        // when the user scrolls. Combine the panel's frosted material with a
        // tint color for visual hierarchy.
        .background(
            ZStack {
                MenuPanelVisualEffectBackground()
                Color.secondary.opacity(0.18)
            }
        )
    }
}

struct DetailInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

struct ResourceRow: View {
    let item: ResourceListItem
    let onOpen: () -> Void
    let onCopyAlias: () -> Void
    let onCopyAddress: () -> Void
    @Binding var selectedDetail: ResourceListItem?
    @Binding var detailPopoverHovered: Bool

    @State private var rowHovered: Bool = false
    @State private var hoverSession: UUID = UUID()

    private var isShowingDetail: Bool { selectedDetail?.id == item.id }
    private var anyHover: Bool {
        // Treat the detail popover as part of "this row" only while it's showing
        // for this row, so other rows aren't affected by it.
        rowHovered || (isShowingDetail && detailPopoverHovered)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.iconName)
                .foregroundColor(rowHovered || isShowingDetail ? .white : .secondary)
                .frame(width: 14)
            Text(item.name).lineLimit(1)
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.caption)
                .opacity(0.6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 24)
        .background(
            (rowHovered || isShowingDetail)
                ? Color.accentColor.opacity(0.85)
                : Color.clear
        )
        .foregroundColor(rowHovered || isShowingDetail ? .white : .primary)
        .contentShape(Rectangle())
        .onHover { hovering in
            rowHovered = hovering
            scheduleHoverUpdate()
        }
        .onChange(of: detailPopoverHovered) {
            // Re-evaluate close timer when the detail panel's hover state changes
            // (e.g., user mouse leaves the NSPanel area).
            if isShowingDetail {
                scheduleHoverUpdate()
            }
        }
        .onTapGesture {
            // Click also shows detail (alternative to hover for accessibility).
            selectedDetail = item
        }
        .contextMenu {
            Button("Open in Browser", action: onOpen)
            Button("Copy Alias", action: onCopyAlias)
            Button("Copy Address", action: onCopyAddress)
        }
    }

    private func scheduleHoverUpdate() {
        let token = UUID()
        hoverSession = token
        // With NSPanel-based detail (no SwiftUI .popover), hover state is reliable —
        // button clicks inside the panel don't toggle .onHover. So we can safely
        // auto-close when neither the row nor the panel is hovered.
        let delay: TimeInterval = anyHover ? 0.2 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard hoverSession == token else { return }
            if anyHover {
                selectedDetail = item
            } else if isShowingDetail {
                selectedDetail = nil
            }
        }
    }
}
