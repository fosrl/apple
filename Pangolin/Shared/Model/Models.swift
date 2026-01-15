//
//  Models.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import Foundation

// MARK: - Configuration

struct Config: Codable {
    var dnsOverrideEnabled: Bool?
    var dnsTunnelEnabled: Bool?
    var primaryDNSServer: String?
    var secondaryDNSServer: String?
}

// MARK: - Account Types

struct Account: Identifiable, Codable, Hashable {
    var id: String { userId }

    let userId: String
    let hostname: String
    let email: String
    var orgId: String
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
    case connecting = "Connecting..."
    case registering = "Registering..."
    case connected = "Connected"
    case reconnecting = "Reconnecting..."
    case disconnecting = "Disconnecting..."
    case invalid = "Invalid"
    case error = "Error"

    var displayText: String {
        // Remove ellipsis from loading states for cleaner display
        switch self {
        case .connecting:
            return "Connecting"
        case .registering:
            return "Registering"
        case .reconnecting:
            return "Reconnecting"
        case .disconnecting:
            return "Disconnecting"
        default:
            return self.rawValue
        }
    }
}

// MARK: - Socket API

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
}

struct SocketSwitchOrgResponse: Codable {
    let status: String
}

struct UpdateMetadataResponse: Codable {
    let status: String
}
