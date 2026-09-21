import Foundation

/// Exposes the app's already-initialized managers to App Intents. Intents run in the
/// app process but outside the SwiftUI view hierarchy, so they never see
/// `PangolinApp`'s `.onAppear` where auth/org state is normally loaded.
@MainActor
final class AppDependencies {
    static let shared = AppDependencies()

    private(set) var tunnelManager: TunnelManager?
    private(set) var authManager: AuthManager?
    private(set) var accountManager: AccountManager?

    private var authLoadTask: Task<Void, Never>?

    private init() {}

    func configure(
        tunnelManager: TunnelManager, authManager: AuthManager, accountManager: AccountManager
    ) {
        self.tunnelManager = tunnelManager
        self.authManager = authManager
        self.accountManager = accountManager
    }

    /// Resolves the app's managers, throwing `.appUnavailable` if `configure` hasn't run yet
    /// (shouldn't normally happen once the app process has launched).
    func requireManagers() throws -> (
        tunnel: TunnelManager, auth: AuthManager, account: AccountManager
    ) {
        guard let tunnelManager, let authManager, let accountManager else {
            throw PangolinIntentError.appUnavailable
        }
        return (tunnelManager, authManager, accountManager)
    }

    /// Loads auth/org state if this process hasn't loaded it yet (e.g. the app was
    /// launched into the background solely to run an intent). Concurrent callers
    /// await the same in-flight load instead of each triggering their own.
    func ensureAuthLoaded() async {
        guard let authManager, authManager.currentOrg == nil else { return }

        if let authLoadTask {
            await authLoadTask.value
            return
        }

        let task = Task { await authManager.initialize() }
        authLoadTask = task
        await task.value
        authLoadTask = nil
    }
}
