import Foundation

/// Returns the platform-appropriate socket path for the OLM socket.
/// On iOS, uses the app group container if available, otherwise falls back to temp directory.
/// On macOS, uses the standard system path.
func getSocketPath() -> String {
    #if os(iOS)
    // On iOS, use a path in the app's container directory (accessible in network extensions)
    // Use the app group container if available, otherwise use a temp directory
    if let appGroupContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.cndf.vpn") {
        return appGroupContainer.appendingPathComponent("olm.sock").path
    } else {
        // Fallback to temp directory if app group is not available
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("olm.sock")
    }
    #else
    // On macOS, use the standard system path
    return "/var/run/olm.sock"
    #endif
}

