import NetworkExtension
import os.log
import PangolinGo

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var tunnelAdapter: TunnelAdapter?
    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "com.cndf.vpn.PacketTunnel"
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
        os_log("Device going to sleep, setting power mode to low", log: logger, type: .info)
        setPowerMode(mode: "low")
        completionHandler()
    }
    
    override func wake() {
        os_log("Device waking up, setting power mode to normal", log: logger, type: .info)
        setPowerMode(mode: "normal")
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

