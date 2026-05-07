import AppKit
import Combine
import Sparkle
import SwiftUI

#if os(macOS)

// MARK: - AppServices (shared bridge between SwiftUI App and AppDelegate)

@MainActor
final class AppServices {
    static let shared = AppServices()
    weak var configManager: ConfigManager?
    weak var secretManager: SecretManager?
    weak var accountManager: AccountManager?
    weak var apiClient: APIClient?
    weak var authManager: AuthManager?
    weak var tunnelManager: TunnelManager?
    weak var onboardingViewModel: MacOnboardingViewModel?
    var updater: SPUUpdater?
    let resourceCache = ResourceCache()
    private init() {}
}

// MARK: - PangolinApp (SwiftUI App)

@main
struct PangolinApp: App {
    @NSApplicationDelegateAdaptor(PangolinAppDelegate.self) var appDelegate

    @StateObject private var configManager = ConfigManager()
    @StateObject private var secretManager = SecretManager()
    @StateObject private var accountManager = AccountManager()
    @StateObject private var apiClient: APIClient
    @StateObject private var authManager: AuthManager
    @StateObject private var tunnelManager: TunnelManager
    @StateObject private var onboardingStateManager: OnboardingStateManager
    @StateObject private var onboardingViewModel: MacOnboardingViewModel

    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        let configMgr = ConfigManager()
        let secretMgr = SecretManager()
        let accountMgr = AccountManager()

        let activeAccount = accountMgr.activeAccount
        let hostname = activeAccount?.hostname ?? ConfigManager.defaultHostname
        let token = activeAccount.flatMap { acct in
            secretMgr.getSessionToken(userId: acct.userId)
        } ?? ""

        let client = APIClient(baseURL: hostname, sessionToken: token)
        let authMgr = AuthManager(
            apiClient: client,
            configManager: configMgr,
            accountManager: accountMgr,
            secretManager: secretMgr
        )
        let tunnelMgr = TunnelManager(
            configManager: configMgr,
            accountManager: accountMgr,
            secretManager: secretMgr,
            authManager: authMgr
        )
        authMgr.tunnelManager = tunnelMgr

        let onboardingState = OnboardingStateManager()
        let onboardingVM = MacOnboardingViewModel(
            onboardingState: onboardingState,
            tunnelManager: tunnelMgr,
            accountManager: accountMgr
        )

        _configManager = StateObject(wrappedValue: configMgr)
        _secretManager = StateObject(wrappedValue: secretMgr)
        _accountManager = StateObject(wrappedValue: accountMgr)
        _apiClient = StateObject(wrappedValue: client)
        _authManager = StateObject(wrappedValue: authMgr)
        _tunnelManager = StateObject(wrappedValue: tunnelMgr)
        _onboardingStateManager = StateObject(wrappedValue: onboardingState)
        _onboardingViewModel = StateObject(wrappedValue: onboardingVM)

        // Publish managers to AppServices for AppDelegate to consume.
        let services = AppServices.shared
        services.configManager = configMgr
        services.secretManager = secretMgr
        services.accountManager = accountMgr
        services.apiClient = client
        services.authManager = authMgr
        services.tunnelManager = tunnelMgr
        services.onboardingViewModel = onboardingVM
        services.updater = updaterController.updater

        // Wire ResourceCache so background polling can run.
        services.resourceCache.apiClient = client
        services.resourceCache.authManager = authMgr
        services.resourceCache.tunnelManager = tunnelMgr
    }

    var body: some Scene {
        // The app no longer uses SwiftUI WindowGroups. All windows (login, onboarding,
        // preferences) are managed by AppWindowsController as plain NSWindows hosting
        // their respective SwiftUI views via NSHostingController. This avoids the
        // SwiftUI WindowGroup + NavigationSplitView layout-cycle crash on macOS 26
        // (_postWindowNeedsUpdateConstraints NSException) and keeps the entire UI
        // shell on AppKit for consistency with the menu bar.
        //
        // The Settings scene is required because SwiftUI's App protocol must declare
        // at least one Scene. We never open it; it's the canonical "no main window"
        // pattern for menu-bar apps.
        Settings { EmptyView() }
    }
}

// MARK: - AppWindowsController
//
// AppKit-managed windows for the SwiftUI views that previously lived in WindowGroups.
// Each window is created lazily on first show, hidden on close (not deallocated), and
// shown again on subsequent requests. Activation policy is updated based on whether
// any of the managed windows are currently visible.

@MainActor
final class AppWindowsController: NSObject, NSWindowDelegate {
    static let shared = AppWindowsController()

    private var loginWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var preferencesWindow: NSWindow?

    func show(id: String) {
        switch id {
        case "main": showLogin()
        case "onboarding": showOnboarding()
        case "preferences": showPreferences()
        default: break
        }
    }

    private func showLogin() {
        if let w = loginWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            updateActivationPolicy()
            return
        }
        guard
            let auth = AppServices.shared.authManager,
            let acct = AppServices.shared.accountManager,
            let cfg = AppServices.shared.configManager,
            let api = AppServices.shared.apiClient
        else { return }
        let view = LoginView(
            authManager: auth, accountManager: acct, configManager: cfg, apiClient: api
        )
        let host = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.contentViewController = host
        window.title = "Pangolin"
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        centerOnScreen(window)
        loginWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateActivationPolicy()
    }

    private func showOnboarding() {
        if let w = onboardingWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            updateActivationPolicy()
            return
        }
        guard let vm = AppServices.shared.onboardingViewModel else { return }
        let view = MacOnboardingFlowView(viewModel: vm)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.contentViewController = host
        window.title = "Pangolin Setup"
        window.identifier = NSUserInterfaceItemIdentifier("onboarding")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        centerOnScreen(window)
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateActivationPolicy()
    }

    private func showPreferences() {
        if let w = preferencesWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            updateActivationPolicy()
            return
        }
        guard
            let cfg = AppServices.shared.configManager,
            let tm = AppServices.shared.tunnelManager
        else { return }
        let view = PreferencesWindow(configManager: cfg, tunnelManager: tm)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.contentViewController = host
        window.title = "Preferences"
        window.identifier = NSUserInterfaceItemIdentifier("preferences")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 800, height: 600))
        centerOnScreen(window)
        preferencesWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateActivationPolicy()
    }

    /// Centers a window horizontally on the active screen and places it slightly
    /// above the vertical center (so it doesn't clip on tall ultra-wide displays
    /// or feel buried behind the dock). Replaces `window.center()`, which on
    /// macOS pins the window's top-third to the screen midline — visually fine
    /// on a single laptop display but unbalanced on large external monitors.
    private func centerOnScreen(_ window: NSWindow) {
        let screen = window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        // Sit ~10% above the visible center for a more "natural" placement.
        let y = visible.midY - size.height / 2 + visible.height * 0.1
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Toggles the dock icon based on whether any managed window is currently visible.
    private func updateActivationPolicy() {
        let anyVisible = [loginWindow, onboardingWindow, preferencesWindow]
            .compactMap { $0 }
            .contains { $0.isVisible }
        if anyVisible {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
        } else {
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    // MARK: NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            // Defer the policy update so the window's `isVisible` reflects the close.
            DispatchQueue.main.async { [weak self] in
                self?.updateActivationPolicy()
            }
        }
    }
}

// MARK: - PangolinAppDelegate

@MainActor
final class PangolinAppDelegate: NSObject, NSApplicationDelegate {
    private var menuController: MainMenuController?
    private var openWindowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon by default; window opens may flip this to .regular.
        NSApp.setActivationPolicy(.accessory)

        // Trigger initial auth (if account exists).
        Task { @MainActor in
            await AppServices.shared.authManager?.initialize()
        }

        // Start background resource polling (only fetches when VPN is connected,
        // so we don't hammer the API while disconnected).
        AppServices.shared.resourceCache.startPolling()

        // Build the menu bar UI.
        menuController = MainMenuController()

        // Route window-open notifications (posted by NSPanel-hosted menu UI) to
        // the AppKit-managed window controller. Replaces the previous SwiftUI
        // OpenWindowBridge scene.
        openWindowObserver = NotificationCenter.default.addObserver(
            forName: .pangolinOpenWindow, object: nil, queue: .main
        ) { notif in
            guard let id = notif.userInfo?["id"] as? String else { return }
            Task { @MainActor in
                AppWindowsController.shared.show(id: id)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    deinit {
        if let obs = openWindowObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}

/// SwiftUI background that uses NSVisualEffectView for the standard menu/panel
/// frosted material — matches the appearance of MenuBarExtra .window popovers.
struct MenuPanelVisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - MainMenuController
//
// AppKit-based menu bar controller: NSStatusItem + NSPanel hosting MenuBarView.
// Replaces SwiftUI's MenuBarExtra so that all popovers (1-depth main, 2-depth
// submenus, 3-depth detail) are uniformly NSPanels with consistent key-window
// and click-handling behavior.

@MainActor
final class MainMenuController: NSObject {
    private let statusItem: NSStatusItem
    private var panel: FocusableMenuPanel?
    private var hostingController: FirstMouseHostingController<AnyView>?

    private var iconCancellable: AnyCancellable?
    private var animTimer: Timer?
    private var animFrame: Int = 1
    private var lastStatus: TunnelStatus = .disconnected

    private var clickMonitor: Any?
    private var hideTimer: Timer?

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel(_:))
        statusItem.button?.sendAction(on: [.leftMouseDown])
        updateIcon()

        // Observe tunnel status changes to update the menu bar icon.
        if let tunnelManager = AppServices.shared.tunnelManager {
            iconCancellable = tunnelManager.$status.sink { [weak self] _ in
                Task { @MainActor in self?.updateIcon() }
            }
        }
    }

    // MARK: Icon updates

    private func updateIcon() {
        guard let tunnelManager = AppServices.shared.tunnelManager else { return }
        let status = tunnelManager.status
        lastStatus = status
        switch status {
        case .connected:
            stopAnimation()
            setConnectedBadgedIcon()
        case .starting, .registering:
            startAnimation()
        default:
            stopAnimation()
            setIcon(named: "MenuBarIconDimmed")
        }
    }

    private func setIcon(named name: String) {
        let image = NSImage(named: name)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    /// Builds and applies an icon with a green ✓ badge in the bottom-right corner —
    /// gives a distinct connected-state cue similar to Microsoft Teams' status badge.
    /// Cached so we don't redraw on every status tick.
    private static var cachedConnectedIcon: NSImage?

    private func setConnectedBadgedIcon() {
        if let cached = MainMenuController.cachedConnectedIcon {
            statusItem.button?.image = cached
            return
        }
        let icon = MainMenuController.makeConnectedBadgedIcon()
        MainMenuController.cachedConnectedIcon = icon
        statusItem.button?.image = icon
    }

    private static func makeConnectedBadgedIcon() -> NSImage? {
        guard let base = NSImage(named: "MenuBarIcon") else { return nil }
        let size = base.size
        let composite = NSImage(size: size, flipped: false) { rect in
            // 1. Render the base icon as a template — manually tint to the menu bar's
            //    current text color so it adapts to light/dark menu bars.
            let menuBarTextColor: NSColor = .labelColor
            if let tinted = MainMenuController.tintedTemplateImage(base, color: menuBarTextColor) {
                tinted.draw(in: rect)
            } else {
                base.draw(in: rect)
            }

            // 2. Bottom-right orange badge (Pangolin brand) with white ring for contrast.
            let badgeDiameter: CGFloat = min(size.width, size.height) * 0.42
            let inset: CGFloat = 0
            let badgeRect = NSRect(
                x: rect.maxX - badgeDiameter - inset,
                y: rect.minY + inset,
                width: badgeDiameter,
                height: badgeDiameter
            )
            // White ring
            NSColor.white.setFill()
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1, dy: -1)).fill()
            // Orange fill
            NSColor(srgbRed: 0.95, green: 0.45, blue: 0.16, alpha: 1).setFill()
            NSBezierPath(ovalIn: badgeRect).fill()

            // 3. White checkmark inside the badge — sized large so it's clearly
            //    visible at menu-bar resolution.
            if let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) {
                let checkConfig = NSImage.SymbolConfiguration(pointSize: badgeDiameter * 0.9, weight: .black)
                let configured = check.withSymbolConfiguration(checkConfig) ?? check
                if let tinted = MainMenuController.tintedTemplateImage(configured, color: .white) {
                    let checkSize = NSSize(width: badgeDiameter * 0.78, height: badgeDiameter * 0.78)
                    let checkRect = NSRect(
                        x: badgeRect.midX - checkSize.width / 2,
                        y: badgeRect.midY - checkSize.height / 2,
                        width: checkSize.width,
                        height: checkSize.height
                    )
                    tinted.draw(in: checkRect)
                }
            }
            return true
        }
        // The composite uses real colors (green badge), not a template.
        composite.isTemplate = false
        return composite
    }

    /// Renders a template NSImage filled with the given color, returning a non-template
    /// copy. Used to render the base logo and the checkmark with explicit colors.
    private static func tintedTemplateImage(_ source: NSImage, color: NSColor) -> NSImage? {
        let size = source.size
        let result = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            color.set()
            rect.fill(using: .sourceIn)
            return true
        }
        result.isTemplate = false
        return result
    }

    private func startAnimation() {
        guard animTimer == nil else { return }
        animFrame = 1
        setIcon(named: "MenuBarIconLoading\(animFrame)")
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // Each timer tick queues a Task on main actor. Between scheduling and
                // execution, the tunnel status may have transitioned to .connected and
                // updateIcon already called setConnectedBadgedIcon. Without this guard,
                // the queued Task would overwrite the connected icon with a loading
                // frame, leaving the icon stuck at "..." even after connection succeeds.
                guard let tm = AppServices.shared.tunnelManager,
                      tm.status == .starting || tm.status == .registering else { return }
                self.animFrame = (self.animFrame % 3) + 1
                self.setIcon(named: "MenuBarIconLoading\(self.animFrame)")
            }
        }
    }

    private func stopAnimation() {
        animTimer?.invalidate()
        animTimer = nil
    }

    // MARK: Panel show/hide

    @objc private func togglePanel(_ sender: Any?) {
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard
            let configManager = AppServices.shared.configManager,
            let accountManager = AppServices.shared.accountManager,
            let apiClient = AppServices.shared.apiClient,
            let authManager = AppServices.shared.authManager,
            let tunnelManager = AppServices.shared.tunnelManager,
            let onboardingViewModel = AppServices.shared.onboardingViewModel,
            let updater = AppServices.shared.updater
        else {
            return
        }

        let menuBarView = MenuBarView(
            configManager: configManager,
            accountManager: accountManager,
            apiClient: apiClient,
            authManager: authManager,
            tunnelManager: tunnelManager,
            updater: updater,
            onboardingViewModel: onboardingViewModel,
            resourceCache: AppServices.shared.resourceCache
        )
        let wrapped = AnyView(
            menuBarView
                .background(MenuPanelVisualEffectBackground())
                .clipShape(RoundedRectangle(cornerRadius: 10))
        )

        // Always create a fresh hosting controller / panel for clean state.
        let host = FirstMouseHostingController(rootView: wrapped)
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize

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
        p.becomesKeyOnlyIfNeeded = false
        p.allowKey = true
        p.contentViewController = host
        panel = p
        hostingController = host

        // Position below the status item button.
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonScreenFrame = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        let origin = NSPoint(
            x: buttonScreenFrame.midX - size.width / 2,
            y: buttonScreenFrame.minY - size.height - 4
        )
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        // Activate the app so the panel can become key reliably; without this,
        // status-item-driven panels often need two clicks because the first one
        // only transfers key.
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)

        installDismissMonitors()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
        removeDismissMonitors()
    }

    // MARK: Dismiss monitors

    private func installDismissMonitors() {
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in self?.hidePanel() }
            }
        }
        // Mouse-out polling so the popover dismisses promptly when the cursor
        // leaves all our windows even if it stops moving outside.
        if hideTimer == nil {
            hideTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkMouseAndMaybeHide() }
            }
        }
    }

    private func removeDismissMonitors() {
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func checkMouseAndMaybeHide() {
        guard panel?.isVisible == true else { return }
        let mouseLocation = NSEvent.mouseLocation
        let inside = NSApp.windows.contains { window in
            window.isVisible && window.frame.contains(mouseLocation)
        }
        if !inside {
            hidePanel()
        }
    }
}

#endif
