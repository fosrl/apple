import AppKit
import Combine
import SwiftUI

/// Shows one submenu at a time in a borderless panel beside the menu bar panel.
///
/// The panel is a child of the menu window and can never become key: the
/// MenuBarExtra window closes as soon as it loses key status, so a submenu
/// that took focus would dismiss the whole menu.
@MainActor
final class MenuSubmenuController: ObservableObject {
    /// NSMenu waits briefly before opening a submenu on hover.
    static let hoverDelay: TimeInterval = 0.12
    /// How long the submenu survives while the pointer crosses other rows on
    /// its way there. It closes if the pointer settles before arriving.
    static let aimTimeout: TimeInterval = 0.3

    @Published private(set) var openID: String?
    /// True while the pointer is crossing rows toward the open submenu. Rows
    /// don't highlight then, so only the submenu's row looks active.
    @Published private(set) var isAimingAtSubmenu = false

    /// While true, nothing opens and any open submenu is closed. Set while the
    /// menu shows its loading state.
    var isSuspended = false {
        didSet {
            if isSuspended { close() }
        }
    }

    /// Opens submenus from rows inside this controller's submenu.
    var child: MenuSubmenuController {
        if let childController { return childController }
        let controller = MenuSubmenuController()
        childController = controller
        return controller
    }

    private var childController: MenuSubmenuController?
    private var panel: SubmenuPanel?
    private var pendingWork: DispatchWorkItem?
    private weak var anchorView: NSView?
    private var mouseMonitor: Any?
    /// The pointer's last position over the open submenu's row, in screen coordinates.
    private var aimOrigin: NSPoint?

    func requestOpen(
        id: String, anchor: NSView, delay: TimeInterval, content: @escaping () -> AnyView
    ) {
        guard !isSuspended else { return }
        if openID == id {
            stopAiming()
            return
        }
        let work = { [weak self, weak anchor] in
            guard let self, let anchor, !self.isSuspended else { return }
            self.open(id: id, anchor: anchor, content: content())
        }
        if openID == nil {
            schedule(after: delay, work)
        } else if isHeadingTowardSubmenu() {
            // Passing over this row on the way to the open submenu.
            isAimingAtSubmenu = true
            schedule(after: Self.aimTimeout, work)
        } else {
            // Moving from one submenu row to another swaps them without waiting.
            schedule(after: 0, work)
        }
    }

    /// Called when the pointer moves onto any other part of the parent menu.
    /// Closes the submenu at once, unless the pointer is on its way to it.
    func pointerEnteredOtherRow() {
        guard openID != nil else {
            // Drops a submenu that was about to open on hover.
            cancelPending()
            return
        }
        if isHeadingTowardSubmenu() {
            isAimingAtSubmenu = true
            schedule(after: Self.aimTimeout) { [weak self] in self?.close() }
        } else {
            close()
        }
    }

    /// Called while the pointer is inside the submenu, so pending closes are dropped.
    fileprivate func pointerEnteredSubmenu() {
        stopAiming()
    }

    func close() {
        stopAiming()
        stopTrackingPointer()
        childController?.close()
        guard let panel else {
            openID = nil
            return
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        // Tear the content down so its views see onDisappear (e.g. to stop polling).
        panel.hostingView.rootView = AnyView(EmptyView())
        openID = nil
    }

    private func cancelPending() {
        pendingWork?.cancel()
        pendingWork = nil
    }

    private func stopAiming() {
        cancelPending()
        aimOrigin = nil
        isAimingAtSubmenu = false
    }

    /// Whether the pointer is inside the triangle between where it left the
    /// submenu's row and the submenu's near edge, like NSMenu's safe zone.
    private func isHeadingTowardSubmenu() -> Bool {
        guard let origin = aimOrigin, let panel, panel.isVisible, let parent = panel.parent else {
            return false
        }
        let frame = panel.frame
        let edgeX = frame.minX >= parent.frame.midX ? frame.minX : frame.maxX
        let top = NSPoint(x: edgeX, y: frame.maxY)
        let bottom = NSPoint(x: edgeX, y: frame.minY)
        return Self.triangle(origin, top, bottom, contains: NSEvent.mouseLocation)
    }

    private static func triangle(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint, contains p: NSPoint) -> Bool {
        func side(_ p1: NSPoint, _ p2: NSPoint, _ p3: NSPoint) -> CGFloat {
            (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
        }
        let d1 = side(p, a, b)
        let d2 = side(p, b, c)
        let d3 = side(p, c, a)
        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNegative && hasPositive)
    }

    private func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        cancelPending()
        let item = DispatchWorkItem(block: work)
        pendingWork = item
        if delay <= 0 {
            item.perform()
            pendingWork = nil
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func open(id: String, anchor: NSView, content: AnyView) {
        guard let parent = anchor.window else { return }
        let panel = self.panel ?? SubmenuPanel()
        self.panel = panel
        anchorView = anchor

        let root = SubmenuRoot(controller: self, content: content)
        panel.hostingView.rootView = AnyView(root)
        panel.appearance = parent.effectiveAppearance
        panel.level = parent.level

        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        openID = id
        reposition(size: panel.hostingView.fittingSize)
        panel.orderFront(nil)
        startTrackingPointer(in: parent)
    }

    /// Records the pointer while it's over the open submenu's row, so a later
    /// move can be judged as heading toward the submenu or not.
    private func startTrackingPointer(in window: NSWindow) {
        recordPointerIfOverAnchor()
        guard mouseMonitor == nil else { return }
        window.acceptsMouseMovedEvents = true
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated {
                self?.recordPointerIfOverAnchor()
            }
            return event
        }
    }

    private func stopTrackingPointer() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
    }

    private func recordPointerIfOverAnchor() {
        guard let anchor = anchorView, let window = anchor.window else { return }
        let rowRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let location = NSEvent.mouseLocation
        if rowRect.contains(location) {
            aimOrigin = location
        }
    }

    /// Places the submenu against the right edge of the anchor row, with its first
    /// row level with it, flipping left when there isn't room, as NSMenu does.
    fileprivate func reposition(size: CGSize) {
        guard let panel, let anchor = anchorView, let parent = anchor.window,
            size.width > 0, size.height > 0
        else { return }

        let rowRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame

        // Butt up against the row's hover highlight, overlapping the parent's
        // edge padding, as native submenus do.
        var x = rowRect.maxX
        if x + size.width > screen.maxX {
            x = rowRect.minX - size.width
        }
        let top = rowRect.maxY + MenuMetrics.panelPadding
        let y = max(screen.minY, min(top, screen.maxY) - size.height)

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

private struct SubmenuRoot: View {
    let controller: MenuSubmenuController
    @ObservedObject var child: MenuSubmenuController
    let content: AnyView

    init(controller: MenuSubmenuController, content: AnyView) {
        self.controller = controller
        self.child = controller.child
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(MenuMetrics.panelPadding)
        .frame(minWidth: MenuMetrics.submenuMinWidth, maxWidth: MenuMetrics.submenuMaxWidth)
        .fixedSize()
        .submenuBackground()
        // Rows inside the submenu open and close the next level down, never the
        // submenu they live in.
        .environment(\.submenuController, child)
        .environment(\.menuSuppressesHover, child.isAimingAtSubmenu)
        .onHover { hovering in
            if hovering { controller.pointerEnteredSubmenu() }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            controller.reposition(size: size)
        }
    }
}

private extension View {
    /// The menu bar panel's own background: Liquid Glass on macOS 26+. Earlier
    /// versions get a visual effect view from `SubmenuPanel` instead.
    @ViewBuilder
    func submenuBackground() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: MenuMetrics.glassCornerRadius, style: .continuous))
        } else {
            self
        }
    }
}

private final class SubmenuPanel: NSPanel {
    let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]

        // On macOS 26+ the SwiftUI content draws the same Liquid Glass as the
        // menu bar panel (see `submenuBackground()`), so the window stays clear.
        if #available(macOS 26.0, *) {
            contentView = hostingView
            return
        }

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = MenuMetrics.panelCornerRadius
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: background.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Holds the AppKit view behind a submenu row so the panel can be placed next to it.
final class MenuAnchor {
    weak var view: NSView?
}

struct MenuAnchorReader: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

private struct SubmenuControllerKey: EnvironmentKey {
    static let defaultValue: MenuSubmenuController? = nil
}

private struct SuppressesHoverKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The controller for submenus opened from the enclosing menu, if any.
    var submenuController: MenuSubmenuController? {
        get { self[SubmenuControllerKey.self] }
        set { self[SubmenuControllerKey.self] = newValue }
    }

    /// True while the pointer crosses rows toward an open submenu; rows skip
    /// their hover highlight then.
    var menuSuppressesHover: Bool {
        get { self[SuppressesHoverKey.self] }
        set { self[SuppressesHoverKey.self] = newValue }
    }
}

/// Closes the MenuBarExtra window the same way a click on the status item does.
///
/// Closing the window directly leaves SwiftUI thinking it's still open, so the
/// next click on the status item does nothing. On macOS 27+ the window belongs
/// to a private "expanded interface session" that has to be cancelled; earlier
/// versions toggle it through the status item button. Both paths are resolved
/// at runtime and do nothing if the private API is missing.
@MainActor
enum MenuBarExtraDismissal {
    private static let statusItemKey = "statusItem"
    private static let sessionSelector = NSSelectorFromString("expandedInterfaceSession")
    private static let cancelSelector = NSSelectorFromString("cancel")

    static func dismiss() {
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            guard window.responds(to: NSSelectorFromString(statusItemKey)),
                let item = window.value(forKey: statusItemKey) as? NSStatusItem
            else { continue }

            if item.responds(to: sessionSelector) {
                if let session = item.perform(sessionSelector)?.takeUnretainedValue() as? NSObject,
                    session.responds(to: cancelSelector)
                {
                    session.perform(cancelSelector)
                    return
                }
            } else if let button = item.button, button.state != .off {
                button.performClick(nil)
                return
            }
        }
    }
}
