import AppKit

/// The native menu shown when the menu bar icon is right-clicked. Its one item
/// stops the tunnel completely, on-demand included, and quits: a way out that
/// doesn't depend on the SwiftUI panel working.
///
/// A right-click on the status item reaches the app as a regular event on the
/// status bar window and doesn't open the MenuBarExtra panel, so a local event
/// monitor can take it over.
@MainActor
final class StatusItemContextMenu: NSObject {
    private let tunnelManager: TunnelManager
    private var monitor: Any?
    private var isQuitting = false

    init(tunnelManager: TunnelManager) {
        self.tunnelManager = tunnelManager
        super.init()
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let window = event.window, window.className.contains("NSStatusBarWindow") else {
                return event
            }
            MainActor.assumeIsolated {
                self?.show(in: window)
            }
            return nil
        }
    }

    private func show(in window: NSWindow) {
        MenuBarExtraDismissal.dismiss()

        let menu = NSMenu()
        let quit = NSMenuItem(
            title: "Quit Pangolin", action: #selector(quitCompletely), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        guard let button = Self.statusButton(in: window.contentView) else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        // Drop the menu just below the icon, like a status item's own menu.
        let y = button.isFlipped ? button.bounds.maxY + 5 : button.bounds.minY - 5
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: y), in: button)
    }

    @objc private func quitCompletely() {
        guard !isQuitting else { return }
        isQuitting = true
        Task {
            await tunnelManager.stopCompletely()
            NSApplication.shared.terminate(nil)
        }
    }

    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = statusButton(in: subview) { return button }
        }
        return nil
    }
}
