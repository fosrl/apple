import Foundation

// MARK: - Configuration

struct Config: Codable {
    var dnsOverrideEnabled: Bool?
    var dnsTunnelEnabled: Bool?
    var primaryDNSServer: String?
    var secondaryDNSServer: String?
    var tunnelMTU: Int?
    /// FQDN wildcard patterns (using * and ? wildcards, e.g. "*.proxy.internal") that olm
    /// should check against local records/upstream DNS. Queries for domains that don't match
    /// any pattern are sent directly to the host's system DNS servers instead. Nil/empty means
    /// match every domain (the feature is disabled).
    var matchDomains: [String]?
    /// When enabled, routes for individual resources are not added to the routing table and
    /// their aliases are not resolved, so all traffic is sent through the exit node instead of
    /// directly to resources. Exit node (gateway) routes are unaffected. Matches olm's
    /// TunnelConfig.DisableRoutesAndAliasesOnExitNode.
    var exitNodeTakesPrecedence: Bool?
    /// When set, overrides Sparkle's automatic update check preference.
    var autoUpdateChecksEnabled: Bool?
    /// When set, overrides Sparkle's automatic download/install preference.
    var autoDownloadUpdatesEnabled: Bool?
    /// When set, overrides Sparkle's scheduled check interval (seconds; minimum 3600).
    var updateCheckIntervalSeconds: Int?

    /// Overrides the cookie name the session token is sent and read under. Nil/empty means use
    /// the API client's built-in default ("p_session_token"). Matches Windows' sessionCookieName.
    var sessionCookieName: String?

    /// On-demand: connect on cellular (iOS) or ethernet (macOS).
    var onDemandNonWiFiEnabled: Bool?
    /// On-demand: connect on Wi-Fi.
    var onDemandWiFiEnabled: Bool?
    /// On-demand SSID filter mode when Wi-Fi is enabled.
    var onDemandSSIDOption: OnDemandSSIDOptionKind?
    /// SSIDs for only/except modes.
    var onDemandSSIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case dnsOverrideEnabled
        case dnsTunnelEnabled
        case primaryDNSServer
        case secondaryDNSServer
        case tunnelMTU
        case matchDomains = "dnsMatchDomains"
        case exitNodeTakesPrecedence
        case autoUpdateChecksEnabled
        case autoDownloadUpdatesEnabled
        case updateCheckIntervalSeconds
        case onDemandNonWiFiEnabled
        case onDemandWiFiEnabled
        case onDemandSSIDOption
        case onDemandSSIDs
        case sessionCookieName
    }
}

// MARK: - Account Types

struct Account: Identifiable, Codable, Hashable {
    var id: String { userId }

    let userId: String
    let hostname: String
    let email: String
    var orgId: String
    var username: String?
    var name: String?
    /// The exit node (a gateway-mode site resource) selected for this account, re-applied on
    /// the next connect. It can differ per account, so it's stored here rather than on the root
    /// config, and it belongs to the account's currently selected org (orgId above). Only the
    /// resource ID is stored (not the niceId, which can be renamed); its sites are looked up
    /// from the server on every connect so they can't go stale.
    var exitNodeResourceId: Int?
}

extension Account {
    var displayName: String {
        if !email.isEmpty {
            return email
        }
        if let name = name, !name.isEmpty {
            return name
        }
        if let username = username, !username.isEmpty {
            return username
        }
        return "Account"
    }
}

struct AccountStore: Codable {
    var activeUserId: String
    var accounts: [String: Account]

    init(activeUserId: String = "", accounts: [String: Account] = [:]) {
        self.accounts = accounts
        self.activeUserId = activeUserId
    }
}

// MARK: - API Response Types

struct APIResponse<T: Codable>: Codable {
    let data: T?
    let success: Bool?
    let error: Bool?
    let message: String?
    let status: Int?
    let stack: String?
}

// MARK: - Authentication

struct LoginRequest: Codable {
    let email: String
    let password: String
    let code: String?
}

struct LoginResponse: Codable {
    let codeRequested: Bool?
    let emailVerificationRequired: Bool?
    let useSecurityKey: Bool?
    let twoFactorSetupRequired: Bool?
}

struct DeviceAuthStartRequest: Codable {
    let applicationName: String
    let deviceName: String?
}

struct DeviceAuthStartResponse: Codable {
    let code: String
    let expiresInSeconds: Int64
}

struct DeviceAuthPollResponse: Codable {
    let verified: Bool
    let message: String?
    let token: String?
}

// MARK: - User

struct User: Codable {
    let userId: String
    let email: String
    let username: String?
    let name: String?
    let type: String?
    let twoFactorEnabled: Bool?
    let emailVerified: Bool?
    let serverAdmin: Bool?
    let idpName: String?
    let idpId: Int?
}

extension User {
    var displayName: String {
        if !email.isEmpty {
            return email
        }
        if let name = name, !name.isEmpty {
            return name
        }
        if let username = username, !username.isEmpty {
            return username
        }
        return "User"
    }
}

// MARK: - Organizations

struct Organization: Codable {
    let orgId: String
    let name: String
    let isOwner: Bool?
}

struct Org: Codable {
    let orgId: String
    let name: String
    // Add other Org fields as needed based on server schema
}

struct GetOrgResponse: Codable {
    let org: Org
}

struct ListUserOrgsResponse: Codable {
    let orgs: [Organization]
    let pagination: Pagination?
}

// MARK: - Organization Access Policy

struct MaxSessionLengthPolicy: Codable {
    let compliant: Bool
    let maxSessionLengthHours: Float
    let sessionAgeHours: Float
}

struct PasswordAgePolicy: Codable {
    let compliant: Bool
    let maxPasswordAgeDays: Float
    let passwordAgeDays: Float
}

struct OrgAccessPolicies: Codable {
    let requiredTwoFactor: Bool?
    let maxSessionLength: MaxSessionLengthPolicy?
    let passwordAge: PasswordAgePolicy?
}

struct CheckOrgUserAccessResponse: Codable {
    let allowed: Bool
    let error: String?
    let policies: OrgAccessPolicies?
}

// MARK: - Client

struct GetClientResponse: Codable {
    let siteIds: [Int]
    let clientId: Int
    let orgId: String
    let exitNodeId: Int?
    let userId: String?
    let name: String
    let pubKey: String?
    let olmId: String?
    let subnet: String
    let megabytesIn: Int?
    let megabytesOut: Int?
    let lastBandwidthUpdate: String?
    let lastPing: Int?
    let type: String
    let online: Bool
    let lastHolePunch: Int?
}

struct Pagination: Codable {
    let total: Int?
    let limit: Int?
    let offset: Int?
}

// MARK: - OLM

struct Olm: Codable {
    let olmId: String
    let userId: String
    let name: String?
    let secret: String?
    let blocked: Bool?
}

struct CreateOlmRequest: Codable {
    let name: String
}

struct CreateOlmResponse: Codable {
    let olmId: String
    let secret: String
}

struct RecoverOlmRequest: Codable {
    let platformFingerprint: String
}

struct RecoverOlmResponse: Codable {
    let olmId: String
    let secret: String
}

// MARK: - Fingerprint/Posture Checks

struct Fingerprint: Codable {
    let username: String
    let hostname: String
    let platform: String
    let osVersion: String
    let kernelVersion: String
    let arch: String
    let deviceModel: String
    let serialNumber: String
    let platformFingerprint: String
}

struct Postures: Codable {
    let autoUpdatesEnabled: Bool
    let biometricsEnabled: Bool
    let diskEncrypted: Bool
    let firewallEnabled: Bool
    let tpmAvailable: Bool

    let macosSipEnabled: Bool
    let macosGatekeeperEnabled: Bool
    let macosFirewallStealthMode: Bool
}

// MARK: - Tunnel Status

enum TunnelStatus: String, CaseIterable {
    case disconnected = "Disconnected"
    case starting = "Starting..."
    case registering = "Registering..."
    case connected = "Connected"

    var displayText: String {
        // Remove ellipsis from loading states for cleaner display
        switch self {
        case .starting:
            return "Starting"
        case .registering:
            return "Registering"
        default:
            return self.rawValue
        }
    }
}

// MARK: - Socket API

struct SocketStatusError: Codable, Equatable {
    let code: String
    let message: String
}

struct SocketStatusResponse: Codable, Equatable {
    let status: String?
    let connected: Bool
    let terminated: Bool
    let tunnelIP: String?
    let version: String?
    let agent: String?
    let peers: [String: SocketPeer]?
    let registered: Bool?
    let orgId: String?
    let networkSettings: NetworkSettings?
    let error: SocketStatusError?
    let exitNode: ExitNodeStatus?
    /// Whether all traffic is routed through a gateway (exit node), the gateway site resource
    /// it was selected from, and the sites currently in use for it.
    let gatewayActive: Bool?
    let gatewaySiteResourceId: Int?
    let gatewaySiteIds: [Int]?
}

struct SocketPeer: Codable, Equatable {
    let siteId: Int?
    let name: String?
    let connected: Bool?
    let rtt: Int64?  // nanoseconds
    let lastSeen: String?
    let endpoint: String?
    let isRelay: Bool?
    let isLocal: Bool?
}

// ExitNodeStatus represents the connectivity status of the client's own exit
// node connection (used for site resources hosted on the exit node).
struct ExitNodeStatus: Codable, Equatable {
    let connected: Bool
    let rtt: Int64?  // nanoseconds
    let lastSeen: String?
    let endpoint: String?
}

struct SiteStatusItem: Identifiable, Equatable {
    let id: String
    let name: String
    let connected: Bool
    let endpoint: String?
    let lastSeen: String?
    /// "Local", "Relay", or "Direct". Nil when the status payload has no connection flags.
    let connection: String?
    /// True when this site is one of those currently used as the exit node (gateway)
    /// that all traffic is routed through.
    let isGateway: Bool

    static func list(from status: SocketStatusResponse) -> [SiteStatusItem] {
        var items: [SiteStatusItem] = []
        if let exitNode = status.exitNode {
            items.append(
                SiteStatusItem(
                    id: "exit-node",
                    name: "Pangolin Server",
                    connected: exitNode.connected,
                    endpoint: exitNode.endpoint,
                    lastSeen: exitNode.lastSeen,
                    connection: nil,
                    isGateway: false
                )
            )
        }
        let gatewaySiteIds: Set<Int> = status.gatewayActive == true ? Set(status.gatewaySiteIds ?? []) : []
        if let peers = status.peers {
            for key in peers.keys.sorted() {
                guard let peer = peers[key] else { continue }
                items.append(
                    SiteStatusItem(
                        id: key,
                        name: peer.name ?? "Unknown",
                        connected: peer.connected ?? false,
                        endpoint: peer.endpoint,
                        lastSeen: peer.lastSeen,
                        connection: connectionLabel(isLocal: peer.isLocal, isRelay: peer.isRelay),
                        isGateway: peer.siteId.map { gatewaySiteIds.contains($0) } ?? false
                    )
                )
            }
        }
        return items
    }

    static func connectionLabel(isLocal: Bool?, isRelay: Bool?) -> String {
        if isLocal == true {
            return "Local"
        }
        if isRelay == true {
            return "Relay"
        }
        return "Direct"
    }
}

extension SocketStatusResponse {
    /// Summarizes the exit node the same way the Windows status does: "Off", or "Active"
    /// followed by the exit node's name in parentheses when it is among `exitNodes`.
    func gatewayLabel(exitNodes: [SiteResource]) -> String {
        guard gatewayActive == true else { return "Off" }
        if let id = gatewaySiteResourceId,
            let name = exitNodes.first(where: { $0.siteResourceId == id })?.name
        {
            return "Active (\(name))"
        }
        return "Active"
    }
}

struct NetworkSettings: Codable, Equatable {
    let tunnelRemoteAddress: String?
    let mtu: Int?
    let dnsServers: [String]?
    let ipv4Addresses: [String]?
    let ipv4SubnetMasks: [String]?
    let ipv4IncludedRoutes: [IPv4Route]?
    let ipv4ExcludedRoutes: [IPv4Route]?
    let ipv6Addresses: [String]?
    let ipv6NetworkPrefixes: [String]?
    let ipv6IncludedRoutes: [IPv6Route]?
    let ipv6ExcludedRoutes: [IPv6Route]?

    enum CodingKeys: String, CodingKey {
        case tunnelRemoteAddress = "tunnel_remote_address"
        case mtu
        case dnsServers = "dns_servers"
        case ipv4Addresses = "ipv4_addresses"
        case ipv4SubnetMasks = "ipv4_subnet_masks"
        case ipv4IncludedRoutes = "ipv4_included_routes"
        case ipv4ExcludedRoutes = "ipv4_excluded_routes"
        case ipv6Addresses = "ipv6_addresses"
        case ipv6NetworkPrefixes = "ipv6_network_prefixes"
        case ipv6IncludedRoutes = "ipv6_included_routes"
        case ipv6ExcludedRoutes = "ipv6_excluded_routes"
    }
}

struct IPv4Route: Codable, Equatable {
    let destinationAddress: String
    let subnetMask: String?
    let gatewayAddress: String?
    let isDefault: Bool?

    enum CodingKeys: String, CodingKey {
        case destinationAddress = "destination_address"
        case subnetMask = "subnet_mask"
        case gatewayAddress = "gateway_address"
        case isDefault = "is_default"
    }
}

struct IPv6Route: Codable, Equatable {
    let destinationAddress: String
    let networkPrefixLength: Int?
    let gatewayAddress: String?
    let isDefault: Bool?

    enum CodingKeys: String, CodingKey {
        case destinationAddress = "destination_address"
        case networkPrefixLength = "network_prefix_length"
        case gatewayAddress = "gateway_address"
        case isDefault = "is_default"
    }
}

struct SocketExitResponse: Codable {
    let status: String
}

struct SocketSwitchOrgRequest: Codable {
    let orgId: String
    
    enum CodingKeys: String, CodingKey {
        case orgId = "org_id"
    }
}

struct SocketSwitchOrgResponse: Codable {
    let status: String
}

struct UpdateMetadataResponse: Codable {
    let status: String
}

struct SocketSelectGatewayRequest: Codable {
    let siteResourceId: Int
    let siteIds: [Int]
}

struct SocketGatewayResponse: Codable {
    let status: String
}

// MARK: - Gateway (Exit Node) Resources

/// A site resource as returned by GET /org/:orgId/site-resources. Only the fields the exit node
/// picker needs are modeled. Gateway-mode resources are what the app calls exit nodes.
struct SiteResource: Codable, Identifiable, Equatable {
    var id: Int { siteResourceId }

    let siteResourceId: Int
    let niceId: String
    let name: String
    let mode: String
    let enabled: Bool
    let siteIds: [Int]
}

struct ListSiteResourcesResponse: Codable {
    let siteResources: [SiteResource]
}

// MARK: - Server Info

struct ServerInfo: Codable {
    let version: String
    let supporterStatusValid: Bool
    let build: String  // "oss" | "enterprise" | "saas"
    let enterpriseLicenseValid: Bool
    let enterpriseLicenseType: String?
}
