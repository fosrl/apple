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

struct ListUserOrgsResponse: Codable {
    let orgs: [Organization]
    let pagination: Pagination?
}

struct Pagination: Codable {
    let total: Int?
    let limit: Int?
    let offset: Int?
}

// MARK: - OLM

struct CreateOlmRequest: Codable {
    let name: String
}

struct CreateOlmResponse: Codable {
    let olmId: String
    let secret: String
}

