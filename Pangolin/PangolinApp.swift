//
//  PangolinApp.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI
import AppKit
import os.log
import Sparkle

struct MenuBarIconView: View {
    @ObservedObject var tunnelManager: TunnelManager
    
    private var tunnelStatus: TunnelStatus {
        tunnelManager.status
    }
    
    var body: some View {
        if tunnelStatus == .connected {
            Image("MenuBarIcon")
                .renderingMode(.template)
        } else {
            Image("MenuBarIconDimmed")
                .renderingMode(.template)
        }
    }
}

@main
struct PangolinApp: App {
    @StateObject private var configManager = ConfigManager()
    @StateObject private var secretManager = SecretManager()
    @StateObject private var apiClient: APIClient
    @StateObject private var authManager: AuthManager
    @StateObject private var tunnelManager: TunnelManager
    
    private let updaterController: SPUStandardUpdaterController
    
    init() {
        // Initialize Sparkle updater
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        let configMgr = ConfigManager()
        let secretMgr = SecretManager()
        let hostname = configMgr.getHostname()
        let token = secretMgr.getSecret(key: "session-token")
        let client = APIClient(baseURL: hostname, sessionToken: token)
        let authMgr = AuthManager(apiClient: client, configManager: configMgr, secretManager: secretMgr)
        let tunnelMgr = TunnelManager(configManager: configMgr, secretManager: secretMgr, authManager: authMgr)
        
        // Set tunnel manager reference in auth manager for org switching
        authMgr.tunnelManager = tunnelMgr
        
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
                tunnelManager: tunnelManager,
                updater: updaterController.updater
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
            MenuBarIconView(tunnelManager: tunnelManager)
        }
        
        // Main Window (Login)
        WindowGroup("Pangolin", id: "main") {
            LoginView(
                authManager: authManager,
                configManager: configManager,
                apiClient: apiClient
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
        .defaultSize(width: 440, height: 300)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        
        // Preferences Window
        WindowGroup("Preferences", id: "preferences") {
            PreferencesWindow(
                configManager: configManager,
                tunnelManager: tunnelManager
            )
            .handlesExternalEvents(preferring: ["preferences"], allowing: ["preferences"])
        }
        .defaultSize(width: 800, height: 600)
        .windowResizability(.contentSize)
        .commands {
            // Hide all menu bar items for preferences window
            CommandGroup(replacing: .appInfo) {}
            CommandGroup(replacing: .appSettings) {}
            CommandGroup(replacing: .appTermination) {}
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .pasteboard) {}
            CommandGroup(replacing: .sidebar) {}
            CommandGroup(replacing: .textEditing) {}
            CommandGroup(replacing: .textFormatting) {}
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(replacing: .undoRedo) {}
        }
    }
}
