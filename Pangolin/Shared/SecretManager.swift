//
//  SecretManager.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import Combine
import Foundation
import Security

class SecretManager: ObservableObject {
    private let service: String = {
        #if os(iOS)
        return "Pangolin: pangolin-iOS"
        #elseif os(macOS)
        return "Pangolin: pangolin-macOS"
        #else
        return "Pangolin"
        #endif
    }()

    private func saveSecret(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            return false
        }

        // Delete existing item if it exists
        _ = deleteSecret(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private func getSecret(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    private func deleteSecret(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Session Tokens

    func getSessionToken(userId: String) -> String? {
        return getSecret(key: "session-token-\(userId)")
    }

    func saveSessionToken(userId: String, token: String) -> Bool {
        return saveSecret(key: "session-token-\(userId)", value: token)
    }

    func deleteSessionToken(userId: String) -> Bool {
        return deleteSecret(key: "session-token-\(userId)")
    }

    // MARK: - OLM Credentials

    func getOlmId(userId: String) -> String? {
        return getSecret(key: "olm-id-\(userId)")
    }

    func getOlmSecret(userId: String) -> String? {
        return getSecret(key: "olm-secret-\(userId)")
    }

    func saveOlmCredentials(userId: String, olmId: String, secret: String) -> Bool {
        let idSaved = saveSecret(key: "olm-id-\(userId)", value: olmId)
        let secretSaved = saveSecret(key: "olm-secret-\(userId)", value: secret)
        return idSaved && secretSaved
    }

    func hasOlmCredentials(userId: String) -> Bool {
        return getOlmId(userId: userId) != nil && getOlmSecret(userId: userId) != nil
    }

    func deleteOlmCredentials(userId: String) -> Bool {
        let idDeleted = deleteSecret(key: "olm-id-\(userId)")
        let secretDeleted = deleteSecret(key: "olm-secret-\(userId)")
        return idDeleted && secretDeleted
    }
}
