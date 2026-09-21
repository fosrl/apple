import Foundation

/// Snapshot of VPN status mirrored into the App Group for the Home Screen widget.
struct VPNWidgetStatusSnapshot: Equatable, Sendable {
    var statusText: String
    var isConnected: Bool
    /// True while connecting / registering — widget shows Disconnect.
    var isBusy: Bool
    var organizationName: String?
    var serverHostname: String?
    var connectedAt: Date?
    var updatedAt: Date

    var showsDisconnectButton: Bool {
        isConnected || isBusy
    }

    static let empty = VPNWidgetStatusSnapshot(
        statusText: "Disconnected",
        isConnected: false,
        isBusy: false,
        organizationName: nil,
        serverHostname: nil,
        connectedAt: nil,
        updatedAt: .distantPast
    )
}

/// Deep links used by the Home Screen widget to open the app and toggle VPN.
enum VPNWidgetDeepLink {
    static let connect = URL(string: "pangolin://vpn/connect")!
    static let disconnect = URL(string: "pangolin://vpn/disconnect")!

    enum Action: String {
        case connect
        case disconnect
    }

    static func action(from url: URL) -> Action? {
        guard url.scheme == "pangolin" else { return nil }
        // pangolin://vpn/connect  → host=vpn, path=/connect
        // pangolin:vpn/connect    → path variants
        let host = url.host?.lowercased()
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if host == "vpn" {
            return Action(rawValue: path)
        }
        if path.hasPrefix("vpn/") {
            return Action(rawValue: String(path.dropFirst(4)))
        }
        return nil
    }
}

/// Pending connect/disconnect request from the Control Center toggle.
/// Written by the control intent; consumed when the app becomes active.
enum VPNWidgetPendingAction: String, Sendable {
    case connect
    case disconnect

    private static let key = "vpnWidget.pendingAction"

    nonisolated private static var defaults: UserDefaults? {
        UserDefaults(suiteName: VPNWidgetStatusStore.appGroupID)
    }

    nonisolated static func set(_ action: VPNWidgetPendingAction) {
        defaults?.set(action.rawValue, forKey: key)
    }

    /// Returns and clears any pending action.
    nonisolated static func take() -> VPNWidgetPendingAction? {
        guard let defaults, let raw = defaults.string(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return VPNWidgetPendingAction(rawValue: raw)
    }
}

/// Reads/writes VPN status for the Home Screen widget via the shared App Group.
enum VPNWidgetStatusStore {
    static let appGroupID = "group.net.pangolin.Pangolin"
    static let widgetKind = "net.pangolin.Pangolin.VPNStatusWidget"
    static let controlKind = "net.pangolin.Pangolin.VPNControl"

    private static let statusTextKey = "vpnWidget.statusText"
    private static let isConnectedKey = "vpnWidget.isConnected"
    private static let isBusyKey = "vpnWidget.isBusy"
    private static let organizationNameKey = "vpnWidget.organizationName"
    private static let serverHostnameKey = "vpnWidget.serverHostname"
    private static let connectedAtKey = "vpnWidget.connectedAt"
    private static let updatedAtKey = "vpnWidget.updatedAt"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func write(
        statusText: String,
        isConnected: Bool,
        isBusy: Bool,
        organizationName: String?,
        serverHostname: String?
    ) {
        guard let defaults else { return }
        defaults.set(statusText, forKey: statusTextKey)
        defaults.set(isConnected, forKey: isConnectedKey)
        defaults.set(isBusy, forKey: isBusyKey)
        setOptionalString(organizationName, forKey: organizationNameKey, in: defaults)
        setOptionalString(displayHostname(from: serverHostname), forKey: serverHostnameKey, in: defaults)

        if isConnected {
            if defaults.object(forKey: connectedAtKey) == nil {
                defaults.set(Date().timeIntervalSince1970, forKey: connectedAtKey)
            }
        } else {
            defaults.removeObject(forKey: connectedAtKey)
        }

        defaults.set(Date().timeIntervalSince1970, forKey: updatedAtKey)
    }

    /// Strips `http(s)://` and trailing slashes so the widget shows just the host.
    static func displayHostname(from raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        // Drop any path after the host (e.g. example.com/app → example.com)
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        return value.isEmpty ? nil : value
    }

    static func read() -> VPNWidgetStatusSnapshot {
        guard let defaults else { return .empty }
        let updatedAt: Date
        if defaults.object(forKey: updatedAtKey) != nil {
            updatedAt = Date(timeIntervalSince1970: defaults.double(forKey: updatedAtKey))
        } else {
            updatedAt = .distantPast
        }
        let connectedAt: Date?
        if defaults.object(forKey: connectedAtKey) != nil {
            connectedAt = Date(timeIntervalSince1970: defaults.double(forKey: connectedAtKey))
        } else {
            connectedAt = nil
        }
        return VPNWidgetStatusSnapshot(
            statusText: defaults.string(forKey: statusTextKey) ?? "Disconnected",
            isConnected: defaults.bool(forKey: isConnectedKey),
            isBusy: defaults.bool(forKey: isBusyKey),
            organizationName: defaults.string(forKey: organizationNameKey),
            serverHostname: displayHostname(from: defaults.string(forKey: serverHostnameKey)),
            connectedAt: connectedAt,
            updatedAt: updatedAt
        )
    }

    private static func setOptionalString(_ value: String?, forKey key: String, in defaults: UserDefaults) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
