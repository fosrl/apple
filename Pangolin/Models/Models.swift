//
//  Models.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import Foundation

// MARK: - Configuration

struct Config: Codable {
    var hostname: String?
    var userId: String?
    var email: String?
    var orgId: String?
    var username: String?
    var name: String?
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
    let expiresAt: Int64
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
    let idpId: String?
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
    let maxSessionLengthHours: Int
    let sessionAgeHours: Int
}

struct PasswordAgePolicy: Codable {
    let compliant: Bool
    let maxPasswordAgeDays: Int
    let passwordAgeDays: Int
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
}

struct CreateOlmRequest: Codable {
    let name: String
}

struct CreateOlmResponse: Codable {
    let olmId: String
    let secret: String
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
        return self.rawValue
    }
}

// MARK: - Socket API

struct SocketStatusResponse: Codable {
    let status: String?
    let connected: Bool
    let tunnelIP: String?
    let version: String?
    let peers: [String: SocketPeer]?
    let registered: Bool?
    let orgId: String?
}

struct SocketPeer: Codable {
    let siteId: Int?
    let connected: Bool?
    let rtt: Int64? // nanoseconds
    let lastSeen: String?
    let endpoint: String?
    let isRelay: Bool?
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

