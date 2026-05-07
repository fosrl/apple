import Foundation

// MARK: - Configuration

struct Config: Codable {
    var dnsOverrideEnabled: Bool?
    var dnsTunnelEnabled: Bool?
    var primaryDNSServer: String?
    var secondaryDNSServer: String?
    var tunnelMTU: Int?
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
}

struct SocketPeer: Codable, Equatable {
    let siteId: Int?
    let name: String?
    let connected: Bool?
    let rtt: Int64?  // nanoseconds
    let lastSeen: String?
    let endpoint: String?
    let isRelay: Bool?
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

// MARK: - User Resources (GET /org/{orgId}/user-resources)

struct UserResource: Codable, Identifiable, Hashable {
    let resourceId: Int
    let name: String
    let domain: String           // e.g. "https://app.example.com"
    let enabled: Bool
    let isProtected: Bool        // true if any of SSO / password / pincode / whitelist is enabled
    let resourceProtocol: String // "http" | "tcp" | "udp" | ...
    let sso: Bool?
    let password: Bool?
    let pincode: Bool?
    let whitelist: Bool?

    enum CodingKeys: String, CodingKey {
        case resourceId, name, domain, enabled
        case isProtected = "protected"
        case resourceProtocol = "protocol"
        case sso, password, pincode, whitelist
    }

    var id: Int { resourceId }
}

struct UserSiteResource: Codable, Identifiable, Hashable {
    let siteResourceId: Int
    let name: String
    let destination: String
    let mode: String             // "host" | "cidr" | "http"
    let scheme: String?          // server exposes this under the "protocol" key (maps to siteResources.scheme)
    let ssl: Bool
    let fullDomain: String?
    let enabled: Bool
    let alias: String?
    let aliasAddress: String?

    enum CodingKeys: String, CodingKey {
        case siteResourceId, name, destination, mode
        case scheme = "protocol"
        case ssl, fullDomain, enabled, alias, aliasAddress
    }

    var id: Int { siteResourceId }
}

struct GetUserResourcesData: Codable {
    let resources: [UserResource]
    let siteResources: [UserSiteResource]
}

// MARK: - Site Resource Detail (GET /org/{orgId}/site-resources)
// Includes port info. Used to augment the /user-resources response.

struct SiteResourceDetail: Codable, Identifiable, Hashable {
    let siteResourceId: Int
    let name: String
    let mode: String
    let destination: String
    let scheme: String?
    let ssl: Bool
    let fullDomain: String?
    let alias: String?
    let aliasAddress: String?
    let tcpPortRangeString: String?
    let udpPortRangeString: String?
    let disableIcmp: Bool?
    let enabled: Bool
    // Site (network) info — present from /org/{orgId}/site-resources. A site resource can
    // belong to multiple sites; we use the first as primary for grouping/display.
    let siteIds: [Int]?
    let siteNames: [String]?
    let siteNiceIds: [String]?
    let siteOnlines: [Bool]?

    var id: Int { siteResourceId }

    var primarySiteName: String? { siteNames?.first }
    var primarySiteOnline: Bool { siteOnlines?.first ?? false }
}

struct ListAllSiteResourcesData: Codable {
    let siteResources: [SiteResourceDetail]
    let pagination: Pagination?
}

// MARK: - Server Info

struct ServerInfo: Codable {
    let version: String
    let supporterStatusValid: Bool
    let build: String  // "oss" | "enterprise" | "saas"
    let enterpriseLicenseValid: Bool
    let enterpriseLicenseType: String?
}
