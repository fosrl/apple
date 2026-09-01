import NetworkExtension
import os.log
import PangolinGo

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var tunnelAdapter: TunnelAdapter?
    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin.PacketTunnel"
        let log = OSLog(subsystem: subsystem, category: "PacketTunnelProvider")
        // Log the subsystem being used for debugging
        os_log("PacketTunnelProvider initialized with subsystem: %{public}@", log: log, type: .debug, subsystem)
        return log
    }()
    
    override init() {
        super.init()
    }
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("startTunnel called with options: %{public}@", log: logger, type: .debug, options?.description ?? "nil")
                
        // Validate that options are provided
        guard let options = options, !options.isEmpty else {
            let error = NSError(domain: "PacketTunnelProvider", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Tunnel options are required but were not provided"
            ])
            os_log("Tunnel start failed: options not provided", log: logger, type: .error)
            completionHandler(error)
            return
        }
        
        // Initialize the tunnel adapter
        tunnelAdapter = TunnelAdapter(with: self)

        // Use the tunnel adapter to start the tunnel and discover the file descriptor
        tunnelAdapter?.start(options: options) { [weak self] (error: Error?) in
            if let error = error {
                os_log("Tunnel start failed: %{public}@", log: self?.logger ?? .default, type: .error, error.localizedDescription)
            } else {
                os_log("Tunnel start completed successfully", log: self?.logger ?? .default, type: .info)
            }
            completionHandler(error)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("stopTunnel called with reason: %d", log: logger, type: .debug, reason.rawValue)
        
        // Use the tunnel adapter to stop the Go tunnel
        if let error = tunnelAdapter?.stop() {
            os_log("Error stopping tunnel adapter: %{public}@", log: logger, type: .error, error.localizedDescription)
        } else {
            os_log("Tunnel stopped successfully", log: logger, type: .info)
        }
        
        completionHandler()
        
        #if os(macOS)
        // HACK: This is a workaround for Apple bug 32073323.
        // System extensions on macOS sometimes don't terminate properly without this.
        exit(0)
        #endif
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Handle messages from the app if needed
        completionHandler?(nil)
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        #if os(iOS)
            // Low power mode disconnects the control websocket and throttles
            // monitoring intervals, which matters on iOS: the extension keeps
            // running in the background under a tight execution/battery budget,
            // and idle pings/reconnect attempts would eat into it for no benefit
            // while the device is asleep or backgrounded.
            os_log("Device going to sleep, setting power mode to low", log: logger, type: .info)
            setPowerMode(mode: "low")
        #else
            // macOS: leave the control websocket connected through sleep rather
            // than tearing it down. Real system sleep halts all process timers,
            // so there's no idle-loop cost to avoid here the way there is on
            // iOS - and leaving it connected keeps its own dead-connection
            // detection (read-deadline/pong, see websocket.Client) armed, so
            // recovery on wake is driven by an actual failed round trip instead
            // of a fixed timer guessing the network is back. See wake() below.
            os_log("Device going to sleep (macOS, leaving control connection intact)", log: logger, type: .info)
        #endif
        completionHandler()
    }

    override func wake() {
        #if os(iOS)
            os_log("Device waking up, setting power mode to normal", log: logger, type: .info)
            setPowerMode(mode: "normal")
        #else
            // Nudge the (never-disconnected) control websocket with an immediate
            // ping rather than forcing a full reconnect: a live connection
            // confirms itself in one round trip, and a dead one starts
            // reconnecting right away via the same path a failed scheduled ping
            // would trigger. See pokeConnection/PokeConnection.
            os_log("Device waking up, poking control connection", log: logger, type: .info)
            pokeConnection()
        #endif
        sweepStaleDNS()
    }

    private func pokeConnection() {
        if let result = PangolinGo.pokeConnection() {
            let message = String(cString: result)
            result.deallocate()
            os_log("pokeConnection returned: %{public}@", log: logger, type: .debug, message)
        } else {
            os_log("Failed to call Go pokeConnection function (returned nil)", log: logger, type: .error)
        }
    }

    // Best-effort cleanup of any stale DNS override left behind by a previous
    // unclean shutdown (e.g. a crashed/killed extension process). wake() is a
    // reliable place to run this: it's invoked by the OS after every sleep.
    private func sweepStaleDNS() {
        if let result = PangolinGo.sweepStaleDNS() {
            let message = String(cString: result)
            result.deallocate()
            os_log("sweepStaleDNS returned: %{public}@", log: logger, type: .debug, message)
        } else {
            os_log("Failed to call Go sweepStaleDNS function (returned nil)", log: logger, type: .error)
        }
    }

    private func setPowerMode(mode: String) {
        let modeCString = mode.utf8CString
        let modePtr = UnsafeMutablePointer<CChar>.allocate(capacity: modeCString.count)
        modeCString.withUnsafeBufferPointer { buffer in
            modePtr.initialize(from: buffer.baseAddress!, count: buffer.count)
        }
        defer {
            modePtr.deallocate()
        }
        
        if let result = PangolinGo.setPowerMode(modePtr) {
            let message = String(cString: result)
            result.deallocate()
            os_log("setPowerMode returned: %{public}@", log: logger, type: .debug, message)
            
            if message.lowercased().contains("error") || message.lowercased().contains("fail") {
                os_log("Failed to set power mode: %{public}@", log: logger, type: .error, message)
            }
        } else {
            os_log("Failed to call Go setPowerMode function (returned nil)", log: logger, type: .error)
        }
    }
}

