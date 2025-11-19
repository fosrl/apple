//
//  MenuBarView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var apiClient: APIClient
    @ObservedObject var authManager: AuthManager
    @ObservedObject var tunnelManager: TunnelManager
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        // Show loading state during initialization
        if authManager.isInitializing {
            HStack {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading...")
                    .foregroundColor(.secondary)
            }
        } else {
            // Connect toggle (when authenticated)
            if authManager.isAuthenticated {
                Text("Status: \(tunnelManager.statusText)")
                    .foregroundColor(.secondary)
                
                UserEmailMenuItem(tunnelManager: tunnelManager)
            }
            
            Divider()
            
            // Email text (when authenticated)
            if authManager.isAuthenticated, let email = authManager.currentUser?.email {
                Text(email)
            }
            
            // Organization selector (when authenticated and has orgs)
            if authManager.isAuthenticated && !authManager.organizations.isEmpty {
                Menu("Organizations") {
                    ForEach(authManager.organizations, id: \.orgId) { org in
                        Text(org.name)
                    }
                }
            }
            
            // Login
            if authManager.isAuthenticated {
                Button("Login to different account") {
                    openLoginWindow()
                }
                .disabled(authManager.isLoading)
            } else {
                Button("Login to account") {
                    openLoginWindow()
                }
                .disabled(authManager.isLoading)
            }
        }
        
        Divider()
        
        // More submenu
        Menu("More") {
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
            
            if !authManager.isInitializing && authManager.isAuthenticated {
                Button("Logout") {
                    Task {
                        await authManager.logout()
                    }
                }
                .disabled(authManager.isLoading)
            }
            
            Divider()
            
            // Copyright
            Text("© 2025 Fossorial, Inc.")
                .foregroundColor(.secondary)
            
            Button("Terms of Service") {
                openURL("https://pangolin.net/terms-of-service.html")
            }
            
            Button("Privacy Policy") {
                openURL("https://pangolin.net/privacy-policy.html")
            }
        }
        
        Divider()
        
        // Quit
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
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
}

struct UserEmailMenuItem: View {
    @ObservedObject var tunnelManager: TunnelManager
    
    var body: some View {
        Button(tunnelManager.isConnected ? "Disconnect" : "Connect") {
            Task {
                if !tunnelManager.isConnected {
                    await tunnelManager.connect()
                } else {
                    await tunnelManager.disconnect()
                }
            }
        }
        .disabled(tunnelManager.isRegistering)
    }
}

