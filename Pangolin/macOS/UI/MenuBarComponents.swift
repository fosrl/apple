import AppKit
import SwiftUI

// Building blocks for the menu bar panel. They follow the system Wi-Fi and
// Bluetooth menus (13pt text, roomy rows, soft gray hover inset from the panel
// edge) so the panel reads as a system menu while hosting live SwiftUI controls.

enum MenuMetrics {
    static let panelWidth: CGFloat = 310
    static let submenuMinWidth: CGFloat = 180
    static let submenuMaxWidth: CGFloat = 340
    /// Corner radius of the pre-Liquid Glass submenu background.
    static let panelCornerRadius: CGFloat = 10
    /// Corner radius of the menu bar panel's Liquid Glass (macOS 26+).
    static let glassCornerRadius: CGFloat = 16
    static let panelPadding: CGFloat = 6
    static let rowHeight: CGFloat = 26
    static let rowHorizontalPadding: CGFloat = 10
    static let highlightRadius: CGFloat = 6
    static let separatorPadding: CGFloat = 6
    static let checkColumnWidth: CGFloat = 14
    static let font = Font.system(size: 13)
    /// Section titles match the Wi-Fi menu: item-sized, bold, and gray.
    static let headerFont = Font.system(size: 13, weight: .semibold)

    /// Leading padding that lines text up with rows that show a check column.
    static func leadingPadding(inset: Bool) -> CGFloat {
        rowHorizontalPadding + (inset ? checkColumnWidth + 5 : 0)
    }
}

/// Menu item look: gray highlight on hover, dimmed text while disabled.
struct MenuItemButtonStyle: ButtonStyle {
    /// Keeps the row highlighted, as NSMenu does for a row whose submenu is open.
    var isHighlightForced = false
    /// Submenu rows manage the submenu themselves, so they opt out of closing it.
    var closesSubmenuOnHover = true

    func makeBody(configuration: Configuration) -> some View {
        MenuItemBody(
            configuration: configuration,
            isHighlightForced: isHighlightForced,
            closesSubmenuOnHover: closesSubmenuOnHover)
    }

    private struct MenuItemBody: View {
        let configuration: Configuration
        let isHighlightForced: Bool
        let closesSubmenuOnHover: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.submenuController) private var submenuController
        @Environment(\.menuSuppressesHover) private var suppressesHover
        @State private var isHovered = false

        private var highlightOpacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.16 }
            return isHighlightForced || (isHovered && !suppressesHover) ? 0.1 : 0
        }

        var body: some View {
            configuration.label
                .font(MenuMetrics.font)
                .lineLimit(1)
                .opacity(isEnabled ? 1 : 0.4)
                .padding(.horizontal, MenuMetrics.rowHorizontalPadding)
                .frame(maxWidth: .infinity, minHeight: MenuMetrics.rowHeight, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: MenuMetrics.highlightRadius, style: .continuous)
                        .fill(Color.primary.opacity(highlightOpacity))
                )
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovered = hovering
                    // Moving onto a plain row dismisses an open sibling submenu.
                    if hovering, closesSubmenuOnHover {
                        submenuController?.pointerEnteredOtherRow()
                    }
                }
        }
    }
}

/// A clickable menu row. `showsCheckColumn` reserves the leading gutter NSMenu
/// uses for state marks, so checked and unchecked rows line up.
struct MenuItem: View {
    let title: String
    var showsCheckColumn = false
    var isChecked = false
    var isLoading = false
    var shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if showsCheckColumn {
                    MenuCheckColumn(isChecked: isChecked, isLoading: isLoading)
                }

                Text(title)
                    .truncationMode(.middle)

                Spacer(minLength: 12)

                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(MenuItemButtonStyle())
    }
}

/// The leading gutter of a checkable row: a checkmark, a spinner, or nothing.
struct MenuCheckColumn: View {
    var isChecked = false
    var isLoading = false

    var body: some View {
        ZStack {
            if isLoading {
                ProgressView().controlSize(.mini)
            } else if isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .frame(width: MenuMetrics.checkColumnWidth)
    }
}

/// A row that opens `content` in a panel beside the menu, like an NSMenu
/// submenu. Hovering opens it after a short delay; clicking opens it at once,
/// or runs `action` instead when the row is also a selectable item.
struct MenuSubmenuItem<Label: View, Content: View>: View {
    let id: String
    @ObservedObject var controller: MenuSubmenuController
    let action: (() -> Void)?
    let content: () -> Content
    let label: () -> Label

    @State private var anchor = MenuAnchor()

    init(
        id: String,
        controller: MenuSubmenuController,
        action: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.id = id
        self.controller = controller
        self.action = action
        self.content = content
        self.label = label
    }

    private var isOpen: Bool { controller.openID == id }

    var body: some View {
        Button {
            if let action {
                action()
            } else {
                open(delay: 0)
            }
        } label: {
            HStack(spacing: 5) {
                label()
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(MenuItemButtonStyle(isHighlightForced: isOpen, closesSubmenuOnHover: false))
        .background(MenuAnchorReader(anchor: anchor))
        .onHover { hovering in
            if hovering { open(delay: MenuSubmenuController.hoverDelay) }
        }
    }

    private func open(delay: TimeInterval) {
        guard let view = anchor.view else { return }
        let content = content
        controller.requestOpen(id: id, anchor: view, delay: delay) {
            AnyView(content())
        }
    }
}

extension MenuSubmenuItem where Label == MenuSubmenuTitle {
    init(
        id: String,
        title: String,
        isLoading: Bool = false,
        dotColor: Color? = nil,
        controller: MenuSubmenuController,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(id: id, controller: controller, content: content) {
            MenuSubmenuTitle(title: title, isLoading: isLoading, dotColor: dotColor)
        }
    }
}

/// The standard submenu row label: optional status dot, title, optional spinner.
struct MenuSubmenuTitle: View {
    let title: String
    var isLoading = false
    var dotColor: Color?

    var body: some View {
        HStack(spacing: 8) {
            if let dotColor {
                MenuStatusDot(color: dotColor)
            }
            Text(title)
                .truncationMode(.middle)
            if isLoading {
                Spacer(minLength: 0)
                ProgressView().controlSize(.mini)
            }
        }
    }
}

/// The small colored circle used for tunnel and site status.
struct MenuStatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .frame(width: 12, height: 12)
    }
}

/// A label and value on one row, for read-only details.
struct MenuDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
            Spacer(minLength: 0)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(MenuMetrics.font)
        .padding(.horizontal, MenuMetrics.rowHorizontalPadding)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: MenuMetrics.rowHeight, alignment: .leading)
    }
}

/// Section title, like `NSMenuItem.sectionHeader(title:)`.
struct MenuSectionHeader: View {
    let title: String
    var inset = false
    @Environment(\.submenuController) private var submenuController

    var body: some View {
        Text(title)
            .font(MenuMetrics.headerFont)
            .foregroundStyle(.secondary)
            .padding(.leading, MenuMetrics.leadingPadding(inset: inset))
            .padding(.trailing, MenuMetrics.rowHorizontalPadding)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, minHeight: MenuMetrics.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { if $0 { submenuController?.pointerEnteredOtherRow() } }
    }
}

/// Non-interactive text, like a disabled NSMenuItem. Wraps instead of truncating.
struct MenuLabel: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary
    var inset = false
    @Environment(\.submenuController) private var submenuController

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(MenuMetrics.font)
        .padding(.leading, MenuMetrics.leadingPadding(inset: inset))
        .padding(.trailing, MenuMetrics.rowHorizontalPadding)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: MenuMetrics.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        // Like any other row, hovering a label dismisses an open submenu.
        .onHover { if $0 { submenuController?.pointerEnteredOtherRow() } }
    }
}

struct MenuSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, MenuMetrics.rowHorizontalPadding)
            .padding(.vertical, MenuMetrics.separatorPadding)
    }
}

/// Reports whether the panel's window is on screen. The MenuBarExtra window
/// keeps its SwiftUI view alive after closing, so `onAppear` only fires once.
struct MenuWindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else {
                report(false)
                return
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let window else { return }
                        self?.report(Self.isOnScreen(window))
                    }
                }
            }
            report(Self.isOnScreen(window))
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { stopObserving() }
        }

        private static func isOnScreen(_ window: NSWindow) -> Bool {
            window.isVisible && window.occlusionState.contains(.visible)
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }

        private func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }
}

/// A row with a trailing switch. Clicking anywhere in the row flips it.
struct MenuToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    /// Overrides the system accent color for the switch.
    var tint: Color?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.submenuController) private var submenuController
    @Environment(\.menuSuppressesHover) private var suppressesHover
    @State private var isHovered = false
    @State private var accent = SystemAccentColor.current

    var body: some View {
        HStack(spacing: 8) {
            // Bold like the Wi-Fi menu's header switch.
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .opacity(isEnabled ? 1 : 0.4)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(tint ?? accent)
        }
        .padding(.horizontal, MenuMetrics.rowHorizontalPadding)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MenuMetrics.highlightRadius, style: .continuous)
                .fill(Color.primary.opacity(isEnabled && isHovered && !suppressesHover ? 0.1 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEnabled else { return }
            isOn.toggle()
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering { submenuController?.pointerEnteredOtherRow() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)) { _ in
            accent = SystemAccentColor.current
        }
    }
}

/// The accent color chosen in System Settings, ignoring the app's own accent.
///
/// `NSColor.controlAccentColor` resolves to the app's AccentColor asset when
/// the user picks Multicolor, so read the global preference instead. Multicolor
/// is stored as no value and shows system blue for controls.
enum SystemAccentColor {
    static var current: Color {
        guard let value = UserDefaults.standard.object(forKey: "AppleAccentColor") as? Int else {
            return Color(nsColor: .systemBlue)
        }
        let color: NSColor
        switch value {
        case -1: color = .systemGray
        case 0: color = .systemRed
        case 1: color = .systemOrange
        case 2: color = .systemYellow
        case 3: color = .systemGreen
        case 5: color = .systemPurple
        case 6: color = .systemPink
        default: color = .systemBlue
        }
        return Color(nsColor: color)
    }
}

extension AnyTransition {
    /// Blurs and fades content in and out, for swapping menu states.
    static var menuBlur: AnyTransition {
        .modifier(active: MenuBlurModifier(progress: 1), identity: MenuBlurModifier(progress: 0))
    }
}

private struct MenuBlurModifier: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: 8 * progress)
            .opacity(1 - progress)
    }
}
