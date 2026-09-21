import ActivityKit
import Foundation

nonisolated struct PangolinVPNAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var statusText: String
        var connectedAt: Date
    }

    var organizationName: String
}
