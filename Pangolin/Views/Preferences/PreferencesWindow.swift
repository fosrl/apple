//
//  PreferencesWindow.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI
import AppKit

struct PreferencesWindow: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager
    @State private var selectedSection: PreferencesSection = .preferences
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            PreferencesSidebar(selectedSection: $selectedSection)
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
        
        // Hide menu bar items when preferences window is key
        hideMenuBarItems()
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
    
    var body: some View {
        List(PreferencesSection.allCases, selection: $selectedSection) { section in
            Label(section.rawValue, systemImage: section.icon)
                .tag(section)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 200)
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
                PreferencesContentView(configManager: configManager)
            case .olmStatus:
                OLMStatusContentView(olmStatusManager: tunnelManager.olmStatusManager)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

