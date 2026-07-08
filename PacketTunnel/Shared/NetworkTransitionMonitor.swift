import Foundation
import Network
import os.log
#if os(macOS)
    import SystemConfiguration
#endif

/// Monitors network path changes and triggers socket rebinding when network transitions occur.
/// This handles cases where the network interface changes (e.g., WiFi to cellular) and the
/// UDP socket becomes stale, causing "network is unreachable" errors.
///
/// It also reports the real (pre-VPN-override) system DNS servers on macOS, since olm cannot
/// read the OS's DNS configuration itself here: the app additionally applies NEDNSSettings (see
/// TunnelAdapter's setTunnelNetworkSettings call) on top of olm's own scutil-based override -
/// unlike the CLI, which only ever adds a non-primary supplemental resolver, NEDNSSettings can
/// become the system's primary resolver, which would make `/etc/resolv.conf` reflect olm's own
/// proxy IP instead of the real upstream DNS. To avoid depending on that, the app build of olm
/// disables its internal /etc/resolv.conf polling entirely (see the `nosysresolver` build tag
/// wired up in apple/Makefile) and relies solely on this class pushing DNS in via SetSystemDNS.
/// The standalone CLI is unaffected either way: it has no Swift/NetworkExtension layer, so it
/// keeps using olm's internal sysresolver_darwin.go as its only source.
///
/// `currentSystemDNSServers` below is macOS-only, via SCDynamicStore's per-service keys, which
/// stay accurate even after the override is installed. There's no iOS equivalent: SCDynamicStore
/// is unavailable to iOS apps, and the only other candidate - the public BSD resolver API
/// (`res_ninit`/`res_getservers`) - turned out to not be usable from Swift either (some of the
/// types it needs fail to import from `<resolv.h>`, for reasons that didn't repay further
/// digging), and even if it were, it only reads the process's global resolver state, so it would
/// stop being accurate the moment NEDNSSettings takes over as the primary resolver anyway. So on
/// iOS this always returns `[]`, and the app instead requires the user to configure at least one
/// upstream DNS server manually before DNS override can be enabled at all (see
/// `ConfigManager.setDNSOverrideEnabled`) - there's no automatic fallback to lean on instead.
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
        os_log(
            "System DNS check: detected %{public}@ (previously reported: %{public}@)", log: logger,
            type: .debug, servers.description, lastReportedDNS.description)
        if servers.isEmpty || servers == lastReportedDNS {
            return
        }
        lastReportedDNS = servers
        os_log("System DNS changed: %{public}@", log: logger, type: .info, servers.description)
        onSystemDNSChanged?(servers)
    }

    private static let staticLogger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin.PacketTunnel"
        return OSLog(subsystem: subsystem, category: "NetworkTransitionMonitor")
    }()

    #if os(macOS)
        /// Reads the real system DNS servers via SCDynamicStore (the same mechanism backing
        /// `scutil --dns`), formatted as "host:53" ready for olm's SetSystemDNS. Also used by
        /// TunnelAdapter for a synchronous read at tunnel start.
        ///
        /// Deliberately reads the primary *service's* own DNS keys
        /// (`Setup:` / `State:/Network/Service/<id>/DNS`) rather than the merged
        /// `State:/Network/Global/DNS`. Once olm's own DNS override is installed - either the
        /// scutil supplemental override or TunnelAdapter's NEDNSSettings, both of which match all
        /// domains ("") - the merged global view reports that override's address as the effective
        /// resolver, permanently masking the physical network's real DNS even across later network
        /// transitions. The per-service keys are untouched by that override. The Go side hits this
        /// same issue and works around it identically; see GetCurrentDNS in
        /// olm/dns/platform/darwin.go.
        ///
        /// `SCDynamicStoreCopyValue`/`SCDynamicStoreCreate` are unavailable to iOS apps - see the
        /// `#else` branch below, and the class doc comment above, for why there's no substitute.
        static func currentSystemDNSServers() -> [String] {
            guard
                let store = SCDynamicStoreCreate(
                    nil, "net.pangolin.Pangolin.PacketTunnel" as CFString, nil, nil)
            else {
                return []
            }
            guard let (serviceID, primaryInterface) = primaryService(store) else {
                return []
            }
            guard let addresses = effectiveDNSServerAddresses(store: store, serviceID: serviceID)
            else {
                return []
            }

            os_log(
                "SCDynamicStore raw DNS addresses: %{public}@, primary interface: %{public}@",
                log: staticLogger, type: .debug, addresses.description, primaryInterface)
            return addresses.map { formatDNSAddress($0, primaryInterface: primaryInterface) }
        }

        /// Returns the DNS servers actually in effect for `serviceID`. `State:/Network/Service/<id>/DNS`
        /// only reflects dynamically-negotiated servers (DHCP/RA) - a manual override set via System
        /// Preferences > Network > Advanced > DNS lives in the separate persistent `Setup:` store and
        /// is never mirrored back into `State:`. Both stores are checked here, with `Setup:` taking
        /// priority when non-empty, to match what the OS itself actually resolves with (this is also
        /// why the old merged `State:/Network/Global/DNS` used to pick up manual overrides - it folds
        /// in `Setup:` too, along with olm's own override, which is what this per-service read avoids).
        private static func effectiveDNSServerAddresses(store: SCDynamicStore, serviceID: String)
            -> [String]?
        {
            if let setup = SCDynamicStoreCopyValue(
                store, "Setup:/Network/Service/\(serviceID)/DNS" as CFString) as? [String: Any],
                let addresses = setup["ServerAddresses"] as? [String],
                !addresses.isEmpty
            {
                return addresses
            }
            if let state = SCDynamicStoreCopyValue(
                store, "State:/Network/Service/\(serviceID)/DNS" as CFString) as? [String: Any],
                let addresses = state["ServerAddresses"] as? [String]
            {
                return addresses
            }
            return nil
        }

        /// Link-local IPv6 DNS servers (e.g. an iPhone Personal Hotspot, which advertises itself
        /// as an RA-supplied RDNSS at a fe80:: address) are meaningless without an interface
        /// scope - the kernel can't route to "fe80::1" without knowing which link it's on. The
        /// per-service State:/Network/Service/<id>/DNS dict doesn't carry that scope either, so it
        /// has to be reattached from the primary interface here, matching what the OS's own
        /// resolver does internally (visible as e.g. "fe80::1%en0" in `scutil --dns`, or "%19" - an
        /// interface index - in `nslookup`'s own output). Without this, dialing the address fails,
        /// olm's health check rejects it, and it silently falls back to the last known-good DNS.
        private static func formatDNSAddress(_ address: String, primaryInterface: String?) -> String {
            var address = address
            if address.lowercased().hasPrefix("fe80:"), !address.contains("%") {
                if let iface = primaryInterface {
                    address += "%\(iface)"
                } else {
                    os_log(
                        "%{public}@ is link-local but no primary interface was found to scope it to",
                        log: staticLogger, type: .default, address)
                }
            }
            return address.contains(":") ? "[\(address)]:53" : "\(address):53"
        }

        /// Returns the primary network service's ID (used to key
        /// `State:/Network/Service/<id>/DNS`) together with its interface name (used to scope
        /// link-local DNS addresses in `formatDNSAddress`).
        private static func primaryService(_ store: SCDynamicStore) -> (
            serviceID: String, interfaceName: String
        )? {
            if let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                as? [String: Any],
                let serviceID = ipv4["PrimaryService"] as? String,
                let iface = ipv4["PrimaryInterface"] as? String
            {
                return (serviceID, iface)
            }
            if let ipv6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString)
                as? [String: Any],
                let serviceID = ipv6["PrimaryService"] as? String,
                let iface = ipv6["PrimaryInterface"] as? String
            {
                return (serviceID, iface)
            }
            return nil
        }
    #else
        /// iOS has no supported way to read the system's real DNS servers (see the class doc
        /// comment above), so there's nothing to report here. DNS override on iOS is instead
        /// required to have an explicit upstream DNS server configured by the user - see
        /// `ConfigManager.setDNSOverrideEnabled` - and olm's own fallback (`Olm.fallbackSystemDNS`)
        /// covers the rest.
        static func currentSystemDNSServers() -> [String] {
            []
        }
    #endif

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
