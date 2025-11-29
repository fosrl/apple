//
//  LogView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI
import AppKit

struct LogView: View {
    @ObservedObject var tunnelManager: TunnelManager
    
    // Computed property to format socket status as JSON
    private var statusJSON: String? {
        guard let socketStatus = tunnelManager.socketStatus else {
            return nil
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let jsonData = try? encoder.encode(socketStatus),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return jsonString
    }
    
    var body: some View {
        TabView {
            OlmStatusView(
                statusJSON: statusJSON
            )
            .tabItem {
                Label("OLM Status", systemImage: "chart.bar.doc.horizontal")
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .background(LogWindowAccessor { window in
            configureWindow(window)
        })
        .onAppear {
            // Show app in dock when window appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard NSApp.activationPolicy() != .regular else { return }
                NSApp.setActivationPolicy(.regular)
                
                // Ensure window identifier is set and close duplicates
                if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "logs" }) {
                    configureWindow(window)
                    
                    // Close any other windows with the same identifier
                    let duplicates = NSApplication.shared.windows.filter { w in
                        w.identifier?.rawValue == "logs" && w != window
                    }
                    for duplicate in duplicates {
                        duplicate.close()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window.identifier?.rawValue == "logs" {
                configureWindow(window)
            }
        }
        .onDisappear {
            // Hide app from dock when window closes (if no other windows)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let hasOtherWindows = NSApplication.shared.windows.contains { window in
                    window.isVisible && (window.identifier?.rawValue == "main" || window.identifier?.rawValue == "logs")
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
        if window.identifier?.rawValue != "logs" {
            window.identifier = NSUserInterfaceItemIdentifier("logs")
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
    }
}

struct OlmStatusView: View {
    let statusJSON: String?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let json = statusJSON {
                    Text(json)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                } else {
                    Text("Unable to get status via socket. Is the tunnel extension running?")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Helper view to access NSWindow
struct LogWindowAccessor: NSViewRepresentable {
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

