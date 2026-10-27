import Foundation

#if canImport(WidgetKit)
import WidgetKit
#endif

/// Snapshot of VPN status mirrored into the App Group for the Home Screen widget.
struct VPNWidgetStatusSnapshot: Equatable, Sendable {
    var statusText: String
    var isConnected: Bool
    /// True while connecting / registering — widget shows Disconnect.
    var isBusy: Bool
    /// On-demand rules are engaged (may be idle if path does not match).
    var isOnDemandEnabled: Bool
    var organizationName: String?
    var serverHostname: String?
    var updatedAt: Date

    var showsDisconnectButton: Bool {
        isConnected || isBusy || isOnDemandEnabled
    }

    nonisolated static let empty = VPNWidgetStatusSnapshot(
        statusText: "Disconnected",
        isConnected: false,
        isBusy: false,
        isOnDemandEnabled: false,
        organizationName: nil,
        serverHostname: nil,
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

    // nonisolated: set/take run from Control Center intents (not MainActor).
    nonisolated private static let key = "vpnWidget.pendingAction"

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
    // Immutable App Group / kind IDs — safe from any isolation (widget, tunnel, intents).
    nonisolated static let appGroupID = "group.net.pangolin.Pangolin"
    nonisolated static let widgetKind = "net.pangolin.Pangolin.VPNStatusWidget"
    nonisolated static let controlKind = "net.pangolin.Pangolin.VPNControl"

    nonisolated private static let statusTextKey = "vpnWidget.statusText"
    nonisolated private static let isConnectedKey = "vpnWidget.isConnected"
    nonisolated private static let isBusyKey = "vpnWidget.isBusy"
    nonisolated private static let isOnDemandEnabledKey = "vpnWidget.isOnDemandEnabled"
    nonisolated private static let organizationNameKey = "vpnWidget.organizationName"
    nonisolated private static let serverHostnameKey = "vpnWidget.serverHostname"
    nonisolated private static let connectedAtKey = "vpnWidget.connectedAt"
    nonisolated private static let updatedAtKey = "vpnWidget.updatedAt"

    nonisolated private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    nonisolated static func write(
        statusText: String,
        isConnected: Bool,
        isBusy: Bool,
        isOnDemandEnabled: Bool,
        organizationName: String?,
        serverHostname: String?
    ) {
        guard let defaults else { return }
        defaults.set(statusText, forKey: statusTextKey)
        defaults.set(isConnected, forKey: isConnectedKey)
        defaults.set(isBusy, forKey: isBusyKey)
        defaults.set(isOnDemandEnabled, forKey: isOnDemandEnabledKey)
        setOptionalString(organizationName, forKey: organizationNameKey, in: defaults)
        setOptionalString(displayHostname(from: serverHostname), forKey: serverHostnameKey, in: defaults)
        // Drop legacy connected-at; duration is no longer shown.
        defaults.removeObject(forKey: connectedAtKey)
        defaults.set(Date().timeIntervalSince1970, forKey: updatedAtKey)
    }

    /// Called from the packet tunnel when the OS starts/stops the VPN (including on-demand).
    /// Preserves org/hostname and on-demand engagement when not explicitly overridden.
    nonisolated static func publishFromTunnelExtension(
        isConnected: Bool,
        isBusy: Bool,
        serverHostname: String? = nil
    ) {
        let existing = read()
        let statusText: String
        if isConnected {
            statusText = "Connected"
        } else if isBusy {
            statusText = "Starting"
        } else if existing.isOnDemandEnabled {
            statusText = "On-Demand Enabled"
        } else {
            statusText = "Disconnected"
        }
        write(
            statusText: statusText,
            isConnected: isConnected,
            isBusy: isBusy,
            isOnDemandEnabled: existing.isOnDemandEnabled,
            organizationName: existing.organizationName,
            serverHostname: serverHostname ?? existing.serverHostname
        )
        reloadTimelines()
    }

    nonisolated static func reloadTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: controlKind)
        }
        #endif
    }

    /// Strips `http(s)://` and trailing slashes so the widget shows just the host.
    nonisolated static func displayHostname(from raw: String?) -> String? {
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

    nonisolated static func read() -> VPNWidgetStatusSnapshot {
        guard let defaults else { return .empty }
        let updatedAt: Date
        if defaults.object(forKey: updatedAtKey) != nil {
            updatedAt = Date(timeIntervalSince1970: defaults.double(forKey: updatedAtKey))
        } else {
            updatedAt = .distantPast
        }
        return VPNWidgetStatusSnapshot(
            statusText: defaults.string(forKey: statusTextKey) ?? "Disconnected",
            isConnected: defaults.bool(forKey: isConnectedKey),
            isBusy: defaults.bool(forKey: isBusyKey),
            isOnDemandEnabled: defaults.bool(forKey: isOnDemandEnabledKey),
            organizationName: defaults.string(forKey: organizationNameKey),
            serverHostname: displayHostname(from: defaults.string(forKey: serverHostnameKey)),
            updatedAt: updatedAt
        )
    }

    nonisolated private static func setOptionalString(
        _ value: String?, forKey key: String, in defaults: UserDefaults
    ) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
