import Foundation
import Network
import os.log
import SystemConfiguration

/// Monitors network path changes and triggers socket rebinding when network transitions occur.
/// This handles cases where the network interface changes (e.g., WiFi to cellular) and the
/// UDP socket becomes stale, causing "network is unreachable" errors.
///
/// It also reports the real (pre-VPN-override) system DNS servers via SCDynamicStore, since
/// olm cannot read either platform's DNS configuration itself here: on iOS there's no
/// meaningful `/etc/resolv.conf` to read, and on macOS the app additionally applies
/// NEDNSSettings (see TunnelAdapter's setTunnelNetworkSettings call) on top of olm's own
/// scutil-based override - unlike the CLI, which only ever adds a non-primary supplemental
/// resolver, NEDNSSettings can become the system's primary resolver, which would make
/// `/etc/resolv.conf` reflect olm's own proxy IP instead of the real upstream DNS. To avoid
/// depending on that, the app build of olm disables its internal /etc/resolv.conf polling
/// entirely (see the `nosysresolver` build tag wired up in apple/Makefile) and relies solely
/// on this class pushing DNS in via SetSystemDNS, the same as Android. The standalone CLI is
/// unaffected either way: it has no Swift/NetworkExtension layer, so it keeps using olm's
/// internal sysresolver_darwin.go as its only source.
class NetworkTransitionMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkTransitionMonitor", qos: .utility)
    private var lastInterfaceType: NWInterface.InterfaceType?
    private var wasUnsatisfied = false

    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin.PacketTunnel"
        return OSLog(subsystem: subsystem, category: "NetworkTransitionMonitor")
    }()

    /// Called when a network transition requires socket rebinding
    var onRebindRequired: (() -> Void)?

    /// Called when the real system DNS servers change, formatted as "host:53"
    /// (or "[host]:53" for IPv6) ready to hand to olm's SetSystemDNS.
    var onSystemDNSChanged: (([String]) -> Void)?
    private var lastReportedDNS: [String] = []
    private var dnsWorkItem: DispatchWorkItem?
    private let dnsDebounceInterval: TimeInterval = 1.0

    /// Debouncing support to prevent excessive rebind calls
    private var rebindWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 2.5

    /// Starts monitoring network path changes
    func start() {
        os_log("Starting network transition monitor", log: logger, type: .debug)

        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        monitor.start(queue: queue)

        // Report an initial best-effort value right away, rather than waiting for the
        // first path update, so olm has a real value as early as possible.
        reportSystemDNSIfChanged()
    }

    /// Stops monitoring network path changes
    func stop() {
        os_log("Stopping network transition monitor", log: logger, type: .debug)

        // Cancel any pending rebind
        rebindWorkItem?.cancel()
        rebindWorkItem = nil

        dnsWorkItem?.cancel()
        dnsWorkItem = nil

        monitor.cancel()
    }

    private func handlePathUpdate(_ path: NWPath) {
        let currentInterfaceType = path.availableInterfaces.first?.type
        let isSatisfied = path.status == .satisfied

        var shouldRebind = false

        // Case 1: Interface type changed (e.g., WiFi -> Cellular)
        if let lastType = lastInterfaceType,
            let currentType = currentInterfaceType,
            lastType != currentType,
            isSatisfied
        {
            shouldRebind = true
            os_log(
                "Network interface changed: %{public}@ -> %{public}@", log: logger, type: .info,
                interfaceTypeString(lastType), interfaceTypeString(currentType))
        }

        // Case 2: Network became available after being unavailable
        if wasUnsatisfied && isSatisfied {
            shouldRebind = true
            os_log(
                "Network became available after being unavailable", log: logger, type: .info)
        }

        // Update state for next comparison
        lastInterfaceType = currentInterfaceType
        wasUnsatisfied = !isSatisfied

        // Trigger rebind if needed (with debouncing)
        if shouldRebind {
            scheduleRebind()
        }

        // DNS can change independently of interface type (e.g. switching between two
        // Wi-Fi networks), so check on every path update, not just shouldRebind.
        if isSatisfied {
            scheduleSystemDNSCheck()
        }
    }

    private func scheduleRebind() {
        // Cancel any pending rebind
        rebindWorkItem?.cancel()

        // Schedule rebind with debounce
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            os_log("Triggering socket rebind after network transition", log: self.logger, type: .info)
            self.onRebindRequired?()
        }
        rebindWorkItem = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func scheduleSystemDNSCheck() {
        dnsWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.reportSystemDNSIfChanged()
        }
        dnsWorkItem = workItem

        queue.asyncAfter(deadline: .now() + dnsDebounceInterval, execute: workItem)
    }

    private func reportSystemDNSIfChanged() {
        let servers = Self.currentSystemDNSServers()
        if servers.isEmpty || servers == lastReportedDNS {
            return
        }
        lastReportedDNS = servers
        os_log("System DNS changed: %{public}@", log: logger, type: .info, servers.description)
        onSystemDNSChanged?(servers)
    }

    /// Reads the real system DNS servers via SCDynamicStore (the same mechanism backing
    /// `scutil --dns`), formatted as "host:53" ready for olm's SetSystemDNS. Also used by
    /// TunnelAdapter for a synchronous read at tunnel start.
    static func currentSystemDNSServers() -> [String] {
        guard
            let store = SCDynamicStoreCreate(
                nil, "net.pangolin.Pangolin.PacketTunnel" as CFString, nil, nil)
        else {
            return []
        }
        guard
            let info = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString)
                as? [String: Any],
            let addresses = info["ServerAddresses"] as? [String]
        else {
            return []
        }
        return addresses.map { address in
            address.contains(":") ? "[\(address)]:53" : "\(address):53"
        }
    }

    private func interfaceTypeString(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi:
            return "WiFi"
        case .cellular:
            return "Cellular"
        case .wiredEthernet:
            return "WiredEthernet"
        case .loopback:
            return "Loopback"
        case .other:
            return "Other"
        @unknown default:
            return "Unknown"
        }
    }
}
