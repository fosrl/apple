import SwiftUI
import AppKit

struct PreferencesWindow: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var authManager: AuthManager
    @ObservedObject var tunnelManager: TunnelManager
    @ObservedObject var onboardingViewModel: MacOnboardingViewModel
    @State private var selectedSection: PreferencesSection = .preferences
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            PreferencesSidebar(
                selectedSection: $selectedSection,
                accountManager: accountManager,
                authManager: authManager,
                tunnelManager: tunnelManager,
                onboardingViewModel: onboardingViewModel
            )
        } detail: {
            // Detail view
            PreferencesDetailView(
                selectedSection: selectedSection,
                configManager: configManager,
                tunnelManager: tunnelManager
            )
        }
        .frame(minWidth: 600, minHeight: 400)
        .background(PreferencesWindowAccessor { window in
            configureWindow(window)
        })
        .onAppear {
            handleWindowAppear()
        }
        .onChange(of: selectedSection) { _ in
            updateWindowTitle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window.identifier?.rawValue == "preferences" {
                configureWindow(window)
                hideMenuBarItems()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window.identifier?.rawValue == "preferences" {
                restoreMenuBarItems()
            }
        }
        .onDisappear {
            handleWindowDisappear()
            restoreMenuBarItems()
        }
    }
    
    private func handleWindowAppear() {
        // Show app in dock when window appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard NSApp.activationPolicy() != .regular else { return }
            NSApp.setActivationPolicy(.regular)
            
            // Ensure window identifier is set and close duplicates
            if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "preferences" }) {
                configureWindow(window)
                
                // Close any other windows with the same identifier
                let duplicates = NSApplication.shared.windows.filter { w in
                    w.identifier?.rawValue == "preferences" && w != window
                }
                for duplicate in duplicates {
                    duplicate.close()
                }
            }
        }
    }
    
    private func handleWindowDisappear() {
        // Hide app from dock when window closes (if no other windows)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let hasOtherWindows = NSApplication.shared.windows.contains { window in
                window.isVisible && (window.identifier?.rawValue == "main" || window.identifier?.rawValue == "preferences")
            }
            if !hasOtherWindows {
                guard NSApp.activationPolicy() != .accessory else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
    
    private func configureWindow(_ window: NSWindow) {
        // Set identifier if not set
        if window.identifier?.rawValue != "preferences" {
            window.identifier = NSUserInterfaceItemIdentifier("preferences")
        }
        
        // Configure window style: allow close, minimize, and maximize
        var styleMask = window.styleMask
        styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        window.styleMask = styleMask
        
        // Show all buttons
        if let minimizeButton = window.standardWindowButton(.miniaturizeButton) {
            minimizeButton.isHidden = false
        }
        if let zoomButton = window.standardWindowButton(.zoomButton) {
            zoomButton.isHidden = false
        }
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.isHidden = false
        }
        
        // Update window title based on current section
        updateWindowTitle()
        
        // Hide menu bar items when preferences window is key
        hideMenuBarItems()
    }
    
    private func updateWindowTitle() {
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "preferences" }) {
            window.title = selectedSection.rawValue
        }
    }
    
    private func hideMenuBarItems() {
        guard let mainMenu = NSApp.mainMenu else { return }
        
        // Hide all menu items except the app name (first item)
        for (index, menuItem) in mainMenu.items.enumerated() {
            if index == 0 {
                // Keep the app name menu but hide its submenu items
                if let submenu = menuItem.submenu {
                    for submenuItem in submenu.items {
                        submenuItem.isHidden = true
                    }
                }
            } else {
                // Hide all other menu items (File, Edit, View, etc.)
                menuItem.isHidden = true
            }
        }
    }
    
    private func restoreMenuBarItems() {
        guard let mainMenu = NSApp.mainMenu else { return }
        
        // Restore all menu items
        for menuItem in mainMenu.items {
            menuItem.isHidden = false
            if let submenu = menuItem.submenu {
                for submenuItem in submenu.items {
                    submenuItem.isHidden = false
                }
            }
        }
    }
}

// MARK: - Sidebar

struct PreferencesSidebar: View {
    @Binding var selectedSection: PreferencesSection
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var authManager: AuthManager
    @ObservedObject var tunnelManager: TunnelManager
    @ObservedObject var onboardingViewModel: MacOnboardingViewModel
    @Environment(\.openWindow) private var openWindow

    private var tunnelStatus: TunnelStatus {
        tunnelManager.status
    }

    /// WireGuard: switch is on when activating/active OR on-demand is engaged.
    private var isToggleOn: Bool {
        switch tunnelStatus {
        case .starting, .registering, .connected:
            return true
        case .disconnected:
            return tunnelManager.isOnDemandEnabled
        }
    }

    private var isInIntermediateState: Bool {
        switch tunnelStatus {
        case .starting, .registering:
            return true
        default:
            return false
        }
    }

    private var shouldDisableToggle: Bool {
        if tunnelManager.hasOnDemandRules { return false }
        return tunnelStatus == .starting
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { isToggleOn },
            set: { newValue in
                guard newValue != isToggleOn else { return }
                performToggle(to: newValue)
            }
        )
    }

    private func performToggle(to newValue: Bool) {
        guard !authManager.sessionExpired else { return }
        if shouldDisableToggle { return }
        Task { @MainActor in
            if newValue {
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

    private var showsConnectionToggle: Bool {
        authManager.isAuthenticated
            && accountManager.activeAccount != nil
            && !authManager.sessionExpired
            && !authManager.isInitializing
    }

    /// Yellow when on-demand engaged but not connected; green otherwise when on.
    private var toggleTint: Color {
        if tunnelManager.isOnDemandEnabled && !isInIntermediateState && tunnelStatus != .connected {
            return .yellow
        }
        return .green
    }

    private var onDemandCaption: String? {
        guard tunnelManager.hasOnDemandRules else { return nil }
        return tunnelManager.isOnDemandEnabled ? "On-Demand Enabled" : "On-Demand Disabled"
    }

    var body: some View {
        VStack(spacing: 0) {
            List(PreferencesSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }

            Group {
                if showsConnectionToggle {
                    Button {
                        performToggle(to: !isToggleOn)
                    } label: {
                        connectionToggle
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(shouldDisableToggle)
                } else {
                    sidebarFooter
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .padding(.top, 4)
        }
        .navigationSplitViewColumnWidth(min: 205, ideal: 205)
    }

    @ViewBuilder
    private var sidebarFooter: some View {
        if authManager.isInitializing {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading...")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if authManager.isAuthenticated, accountManager.activeAccount != nil, authManager.sessionExpired {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 36, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Account Locked")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Button("Log In") {
                        authManager.startDeviceAuthImmediately = true
                        openLoginWindow()
                    }
                    .buttonStyle(.link)
                    .disabled(authManager.isDeviceAuthInProgress)
                }
                Spacer(minLength: 0)
            }
        } else {
            Button("Login") {
                openLoginWindow()
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    private var connectionToggle: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: toggleBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .tint(toggleTint)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tunnelStatus.displayText)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if isInIntermediateState {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }

                if let onDemandCaption {
                    Text(onDemandCaption)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openLoginWindow() {
        DispatchQueue.main.async {
            guard NSApp.activationPolicy() != .regular else { return }
            NSApp.setActivationPolicy(.regular)
        }

        let existingWindow = NSApplication.shared.windows.first { window in
            window.identifier?.rawValue == "main" || window.title == "Pangolin"
        }

        if let window = existingWindow {
            let allMainWindows = NSApplication.shared.windows.filter { w in
                (w.identifier?.rawValue == "main" || w.title == "Pangolin") && w != window
            }
            for duplicateWindow in allMainWindows {
                duplicateWindow.close()
            }

            var styleMask = window.styleMask
            styleMask.remove([.miniaturizable, .resizable])
            styleMask.insert([.titled, .closable])
            window.styleMask = styleMask

            if let minimizeButton = window.standardWindowButton(.miniaturizeButton) {
                minimizeButton.isHidden = true
            }
            if let zoomButton = window.standardWindowButton(.zoomButton) {
                zoomButton.isHidden = true
            }
            if let closeButton = window.standardWindowButton(.closeButton) {
                closeButton.isHidden = false
            }

            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)

            if window.identifier?.rawValue != "main" {
                window.identifier = NSUserInterfaceItemIdentifier("main")
            }
        } else {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)

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
}

// MARK: - Detail View

struct PreferencesDetailView: View {
    let selectedSection: PreferencesSection
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager
    
    var body: some View {
        // Content
        Group {
            switch selectedSection {
            case .preferences:
                PreferencesContentView(
                    configManager: configManager,
                    tunnelManager: tunnelManager
                )
            case .olmStatus:
                OLMStatusContentView(olmStatusManager: tunnelManager.olmStatusManager)
            case .about:
                AboutContentView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

