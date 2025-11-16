//
//  MainWindowView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI
import AppKit

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

struct MainWindowView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var apiClient: APIClient
    @ObservedObject var authManager: AuthManager
    @ObservedObject var tunnelManager: TunnelManager
    @Environment(\.colorScheme) private var colorScheme
    
    private var windowBackgroundColor: Color {
        colorScheme == .dark ? Color(hex: "161618") : Color(hex: "FDFDFD")
    }
    
    var body: some View {
        LoginView(
            authManager: authManager,
            configManager: configManager,
            apiClient: apiClient
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(windowBackgroundColor)
        .background(WindowAccessor { window in
            configureWindow(window)
        })
        .onAppear {
            // Show app in dock when window appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard NSApp.activationPolicy() != .regular else { return }
                NSApp.setActivationPolicy(.regular)
                
                // Ensure window identifier is set and close duplicates
                // Find this window by title first
                if let window = NSApplication.shared.windows.first(where: { $0.title == "Pangolin" }) {
                    configureWindow(window)
                    
                    // Close any other windows with the same identifier or title
                    let duplicates = NSApplication.shared.windows.filter { w in
                        (w.identifier?.rawValue == "main" || w.title == "Pangolin") && w != window
                    }
                    for duplicate in duplicates {
                        duplicate.close()
                    }
                    
                    // Bring window to front
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window.identifier?.rawValue == "main" {
                configureWindow(window)
            }
        }
        .onDisappear {
            // Hide app from dock when window closes (if no other windows)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let hasOtherWindows = NSApplication.shared.windows.contains { window in
                    window.isVisible && window.identifier?.rawValue == "main"
                }
                if !hasOtherWindows {
                    guard NSApp.activationPolicy() != .accessory else { return }
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
    
    private func configureWindow(_ window: NSWindow) {
        // Set identifier if not set
        if window.identifier?.rawValue != "main" {
            window.identifier = NSUserInterfaceItemIdentifier("main")
        }
        
        // Configure window style: remove minimize and maximize, keep close button
        var styleMask = window.styleMask
        styleMask.remove([.miniaturizable, .resizable])
        styleMask.insert([.titled, .closable])
        window.styleMask = styleMask
        
        // Ensure resizing is disabled
        window.styleMask.remove(.resizable)
        
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
        
        // Set window to not be resizable
        window.isMovableByWindowBackground = false
    }
}

// Helper view to access NSWindow
struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let window = view.window {
                callback(window)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = nsView.window {
                callback(window)
            }
        }
    }
}
