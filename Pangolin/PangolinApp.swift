//
//  PangolinApp.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI
import AppKit

@main
struct PangolinApp: App {
    @StateObject private var configManager = ConfigManager()
    @StateObject private var secretManager = SecretManager()
    @StateObject private var apiClient: APIClient
    @StateObject private var authManager: AuthManager
    @StateObject private var tunnelManager: TunnelManager
    
    
    init() {
        let configMgr = ConfigManager()
        let secretMgr = SecretManager()
        let hostname = configMgr.getHostname()
        let token = secretMgr.getSecret(key: "session-token")
        let client = APIClient(baseURL: hostname, sessionToken: token)
        let authMgr = AuthManager(apiClient: client, configManager: configMgr, secretManager: secretMgr)
        let tunnelMgr = TunnelManager(configManager: configMgr, secretManager: secretMgr, authManager: authMgr)
        
        _configManager = StateObject(wrappedValue: configMgr)
        _secretManager = StateObject(wrappedValue: secretMgr)
        _apiClient = StateObject(wrappedValue: client)
        _authManager = StateObject(wrappedValue: authMgr)
        _tunnelManager = StateObject(wrappedValue: tunnelMgr)
    }
    
    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                configManager: configManager,
                apiClient: apiClient,
                authManager: authManager,
                tunnelManager: tunnelManager
            )
            .onAppear {
                // Set activation policy to accessory (menu bar only) on first appearance
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard NSApp.activationPolicy() != .accessory else { return }
                    NSApp.setActivationPolicy(.accessory)
                }
                
                Task {
                    await authManager.initialize()
                }
            }
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
        }
        
        // Main Window (Login)
        WindowGroup("Pangolin", id: "main") {
            MainWindowView(
                configManager: configManager,
                apiClient: apiClient,
                authManager: authManager,
                tunnelManager: tunnelManager
            )
            .handlesExternalEvents(preferring: ["main"], allowing: ["main"])
            .onAppear {
                // Ensure window has correct identifier
                DispatchQueue.main.async {
                    if let window = NSApplication.shared.windows.first(where: { $0.title == "Pangolin" }) {
                        window.identifier = NSUserInterfaceItemIdentifier("main")
                    }
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 500, height: 450)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
