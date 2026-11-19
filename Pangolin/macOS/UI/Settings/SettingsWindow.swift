import SwiftUI
import AppKit

struct SettingsWindow: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var authManager: AuthManager
    @State private var selectedSection: SettingsSection = .general
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            SettingsSidebar(selectedSection: $selectedSection)
        } detail: {
            // Detail view
            SettingsDetailView(
                selectedSection: selectedSection,
                configManager: configManager,
                tunnelManager: tunnelManager,
                accountManager: accountManager,
                authManager: authManager
            )
        }
        .frame(minWidth: 600, minHeight: 400)
        .background(SettingsWindowAccessor { window in
            configureWindow(window)
        })
        .onAppear {
            handleWindowAppear()
        }
        .onChange(of: selectedSection) {
            updateWindowTitle()
        }
        .onReceive(SettingsNavigation.shared.$requestedSection) { section in
            guard let section else { return }
            selectedSection = section
            SettingsNavigation.shared.requestedSection = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window.identifier?.rawValue == "settings" {
                configureWindow(window)
                hideMenuBarItems()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window.identifier?.rawValue == "settings" {
                restoreMenuBarItems()
            }
        }
        .onDisappear {
            handleWindowDisappear()
            restoreMenuBarItems()
        }
    }
    
    private func handleWindowAppear() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            showAppInDock()
            closeDuplicateSettingsWindows()
        }
        // Launch hides the Dock icon shortly after this window is restored.
        // Re-apply once that has run, if the window is still open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard isSettingsWindowShown() else { return }
            showAppInDock()
        }
    }

    private func showAppInDock() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func isSettingsWindowShown() -> Bool {
        NSApplication.shared.windows.contains { window in
            let isShown = window.isVisible || window.isMiniaturized
            guard isShown else { return false }
            if window.identifier?.rawValue == "settings" { return true }
            return SettingsSection.allCases.contains { $0.rawValue == window.title }
        }
    }

    private func closeDuplicateSettingsWindows() {
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
            configureWindow(window)

            let duplicates = NSApplication.shared.windows.filter { w in
                w.identifier?.rawValue == "settings" && w != window
            }
            for duplicate in duplicates {
                duplicate.close()
            }
        }
    }
    
    private func handleWindowDisappear() {
        // Hide app from dock when window closes (if no other windows)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let hasOtherWindows = NSApplication.shared.windows.contains { window in
                window.isVisible && window.identifier?.rawValue == "settings"
            }
            if !hasOtherWindows {
                guard NSApp.activationPolicy() != .accessory else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
    
    private func configureWindow(_ window: NSWindow) {
        // Set identifier if not set
        if window.identifier?.rawValue != "settings" {
            window.identifier = NSUserInterfaceItemIdentifier("settings")
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
        
        // Hide menu bar items when settings window is key
        hideMenuBarItems()
    }
    
    private func updateWindowTitle() {
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
        window.title = selectedSection.rawValue
        window.titlebarSeparatorStyle = selectedSection == .olmStatus ? .none : .automatic
    }
    }
    
    private func hideMenuBarItems() {
        guard let mainMenu = NSApp.mainMenu else { return }
        
        // Hide all menu items except the app name (first item).
        // Hidden items ignore key equivalents unless this flag is set, which
        // would disable Select All, copy, and paste in text fields.
        for (index, menuItem) in mainMenu.items.enumerated() {
            if index == 0 {
                // Keep the app name menu but hide its submenu items
                if let submenu = menuItem.submenu {
                    for submenuItem in submenu.items {
                        submenuItem.allowsKeyEquivalentWhenHidden = true
                        submenuItem.isHidden = true
                    }
                }
            } else {
                // Hide all other menu items (File, Edit, View, etc.)
                allowKeyEquivalentsWhenHidden(menuItem)
                menuItem.isHidden = true
            }
        }
    }

    private func allowKeyEquivalentsWhenHidden(_ menuItem: NSMenuItem) {
        menuItem.allowsKeyEquivalentWhenHidden = true
        guard let submenu = menuItem.submenu else { return }
        for submenuItem in submenu.items {
            allowKeyEquivalentsWhenHidden(submenuItem)
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

struct SettingsSidebar: View {
    @Binding var selectedSection: SettingsSection

    var body: some View {
        List(SettingsSection.allCases, selection: $selectedSection) { section in
            Label(section.rawValue, systemImage: section.icon)
                .tag(section)
        }
        .navigationSplitViewColumnWidth(min: 192, ideal: 192)
    }
}

// MARK: - Detail View

struct SettingsDetailView: View {
    let selectedSection: SettingsSection
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager
    let accountManager: AccountManager
    let authManager: AuthManager
    
    var body: some View {
        // Content
        Group {
            switch selectedSection {
            case .general:
                GeneralSettingsView(
                    configManager: configManager,
                    tunnelManager: tunnelManager
                )
            case .connection:
                ConnectionSettingsView(
                    configManager: configManager,
                    tunnelManager: tunnelManager
                )
            case .accounts:
                AccountsContentView(
                    accountManager: accountManager,
                    authManager: authManager,
                    tunnelManager: tunnelManager
                )
            case .olmStatus:
                OLMStatusContentView(
                    olmStatusManager: tunnelManager.olmStatusManager,
                    exitNodes: tunnelManager.availableExitNodes
                )
            case .about:
                AboutContentView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

