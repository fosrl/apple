//
//  MenuBarView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI
import AppKit
import Sparkle

struct MenuBarView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var apiClient: APIClient
    @ObservedObject var authManager: AuthManager
    @ObservedObject var tunnelManager: TunnelManager
    let updater: SPUUpdater
    @Environment(\.openWindow) private var openWindow
    @State private var menuOpenCount = 0
    @State private var isLoggedOut = false
    
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
            // Connect toggle (when authenticated and not logged out)
            if authManager.isAuthenticated && !isLoggedOut {
                Text(tunnelManager.status.displayText)
                    .foregroundColor(.secondary)
                
                UserEmailMenuItem(tunnelManager: tunnelManager)
            }
            
            // Check if user has previously logged in (has saved email)
            let hasSavedUserInfo = configManager.config?.email != nil
            
            // Email text (when authenticated or has saved user info)
            if authManager.isAuthenticated || hasSavedUserInfo {
                Group {
                    if authManager.isAuthenticated {
                        if let email = authManager.currentUser?.email {
                            Text(isLoggedOut ? "\(email) (Logged out)" : email)
                        } else if let savedEmail = configManager.config?.email {
                            Text("\(savedEmail) (Logged out)")
                        }
                    } else if let savedEmail = configManager.config?.email {
                        // Not authenticated but has saved email - show logged out state
                        Text("\(savedEmail) (Logged out)")
                    }
                }
                .id(menuOpenCount) // Force view recreation to trigger task
                .task {
                    // Handle menu open logic when menu opens (only if authenticated)
                    if authManager.isAuthenticated {
                        await handleMenuOpen()
                    }
                }
            }
            
            // Organization selector (when authenticated, has orgs, and not logged out)
            if authManager.isAuthenticated && !authManager.organizations.isEmpty && !isLoggedOut {
                OrganizationsMenu(authManager: authManager, tunnelManager: tunnelManager)
            }
            
            // Login button
            if authManager.isAuthenticated {
                Button(isLoggedOut ? "Log back in" : "Log in to different account") {
                    if !isLoggedOut {
                        Task {
                            openLoginWindow()
                        }
                    } else {
                        // Log back in - just open login window
                        openLoginWindow()
                    }
                }
            } else if hasSavedUserInfo {
                // Has saved user info but not authenticated - show "Log back in"
                Button("Log back in") {
                    openLoginWindow()
                }
            } else {
                // Never logged in before - show "Login to account"
                Button("Log in to account") {
                    openLoginWindow()
                }
            }
        }
        
        Divider()
        
        // More submenu
        Menu("More") {
            if !authManager.isInitializing && authManager.isAuthenticated && !isLoggedOut {
                Button("Logout") {
                    Task {
                        await authManager.logout()
                    }
                }
            }
            
            Divider()
            
            // Support section
            Text("Support")
                .foregroundColor(.secondary)
            
            Button("How Pangolin Works") {
                openURL("https://docs.pangolin.net/")
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
            Text("Version: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")")
                .foregroundColor(.secondary)
            
            CheckForUpdatesView(updater: updater)
        }
        
        Divider()
        
        // Quit
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
        }
        .onAppear {
            // Increment counter to force view recreation and trigger task
            menuOpenCount += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
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
        // First, try to get the user to verify session is still valid
        do {
            let user = try await apiClient.getUser()
            // If successful, update user and clear logged out state
            await MainActor.run {
                authManager.currentUser = user
                isLoggedOut = false
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
            
            // Make window float on top of all other windows
            window.level = .floating
            
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
                    // Make window float on top of all other windows
                    window.level = .floating
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
        case .connecting, .registering, .reconnecting, .disconnecting:
            return true
        default:
            return false
        }
    }
    
    var body: some View {
        Menu {
            // Show organization count
            Text(organizations.count == 1 ? "1 Organization" : "\(organizations.count) Organizations")
                .foregroundColor(.secondary)
            
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

struct UserEmailMenuItem: View {
    @ObservedObject var tunnelManager: TunnelManager
    
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
        .disabled(tunnelManager.isRegistering)
    }
}

