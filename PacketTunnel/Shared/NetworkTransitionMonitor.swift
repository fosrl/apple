import Foundation
import Network
import os.log

/// Monitors network path changes and triggers socket rebinding when network transitions occur.
/// This handles cases where the network interface changes (e.g., WiFi to cellular) and the
/// UDP socket becomes stale, causing "network is unreachable" errors.
class NetworkTransitionMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkTransitionMonitor", qos: .utility)
    private var lastInterfaceType: NWInterface.InterfaceType?
    private var wasUnsatisfied = false
    
    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "com.cndf.vpn.PacketTunnel"
        return OSLog(subsystem: subsystem, category: "NetworkTransitionMonitor")
    }()
    
    /// Called when a network transition requires socket rebinding
    var onRebindRequired: (() -> Void)?
    
    /// Debouncing support to prevent excessive rebind calls
    private var rebindWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 2.5
    
    /// Starts monitoring network path changes
    func start() {
        // os_log("Network transition monitor disabled (temporarily)", log: logger, type: .debug)
        // return
        
        os_log("Starting network transition monitor", log: logger, type: .debug)
        
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        monitor.start(queue: queue)
    }
    
    /// Stops monitoring network path changes
    func stop() {
        os_log("Stopping network transition monitor", log: logger, type: .debug)
        
        // Cancel any pending rebind
        rebindWorkItem?.cancel()
        rebindWorkItem = nil
        
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
           isSatisfied {
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
