import Combine
import Foundation
import SwiftUI
import os.log

class AccountManager: ObservableObject {
    @Published private(set) var store: AccountStore = .init()

    var activeAccount: Account? {
        if store.activeUserId.isEmpty {
            return nil
        }

        return store.accounts[store.activeUserId]
    }

    var accounts: [String: Account] {
        return store.accounts
    }

    var activeUserId: String {
        store.activeUserId
    }

    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return OSLog(subsystem: subsystem, category: "AccountManager")
    }()

    init() {
        // Migrate data from sandboxed location if needed (macOS only)
        #if os(macOS)
        _ = SandboxMigration.migrateIfNeeded()
        #endif
        load()
    }

    func load() {
        let url = AccountStoreLocation.url

        guard FileManager.default.fileExists(atPath: url.path) else {
            store = .init()
            return
        }

        do {
            let data = try Data(contentsOf: url)

            store = try JSONDecoder().decode(AccountStore.self, from: data)
        } catch {
            os_log(
                "Error loading account store: %{public}@", log: logger, type: .error,
                error.localizedDescription)
            store = .init()
        }
    }

    func save() -> Bool {
        let url = AccountStoreLocation.url

        do {
            let data = try JSONEncoder().encode(store)

            try data.write(to: url, options: [.atomic])

            return true
        } catch {
            os_log(
                "Error saving account store: %{public}@", log: logger, type: .error,
                error.localizedDescription)

            return false
        }
    }

    func addAccount(_ account: Account, makeActive: Bool = false) {
        store.accounts[account.userId] = account

        if makeActive {
            store.activeUserId = account.userId
        }

        _ = save()
    }

    func setActiveUser(userId: String) {
        guard store.accounts[userId] != nil else {
            return
        }

        store.activeUserId = userId

        _ = save()
    }

    func setUserOrganization(userId: String, orgId: String) {
        if var account = store.accounts[userId] {
            account.orgId = orgId
            store.accounts[userId] = account
        }

        _ = save()
    }
    
    func updateAccountUserInfo(userId: String, username: String?, name: String?) {
        if var account = store.accounts[userId] {
            account.username = username
            account.name = name
            store.accounts[userId] = account
            _ = save()
        }
    }

    func activateAccount(userId: String) {
        guard store.accounts[userId] != nil else {
            os_log("Selected account %{public}@ oes not exist", log: logger, type: .error, userId)
            return
        }

        store.activeUserId = userId

        _ = save()
    }

    func removeAccount(userId: String) {
        store.accounts.removeValue(forKey: userId)

        if store.activeUserId == userId {
            store.activeUserId = ""
        }

        _ = save()
    }
}

enum AccountStoreLocation {
    static var url: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        let dir = base.appendingPathComponent("Pangolin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        return dir.appendingPathComponent("accounts.json")
    }
}
