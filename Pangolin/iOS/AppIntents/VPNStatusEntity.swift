import AppIntents

struct VPNStatusEntity: TransientAppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Pangolin VPN Status"

    var isConnected: Bool
    var statusText: String
    var organizationName: String?
    var serverHostname: String?

    init() {
        isConnected = false
        statusText = ""
        organizationName = nil
        serverHostname = nil
    }

    init(isConnected: Bool, statusText: String, organizationName: String?, serverHostname: String?)
    {
        self.isConnected = isConnected
        self.statusText = statusText
        self.organizationName = organizationName
        self.serverHostname = serverHostname
    }

    var displayRepresentation: DisplayRepresentation {
        guard let organizationName else {
            return DisplayRepresentation(title: "\(statusText)")
        }
        return DisplayRepresentation(title: "\(statusText)", subtitle: "\(organizationName)")
    }
}
