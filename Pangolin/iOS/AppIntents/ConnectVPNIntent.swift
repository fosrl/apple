import AppIntents

struct ConnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect Pangolin VPN"
    static var description = IntentDescription("Enables the Pangolin VPN connection.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (tunnelManager, authManager, _) = try AppDependencies.shared.requireManagers()

        await AppDependencies.shared.ensureAuthLoaded()

        guard authManager.isAuthenticated else {
            throw PangolinIntentError.notLoggedIn
        }
        guard authManager.currentOrg != nil else {
            throw PangolinIntentError.noOrganizationSelected
        }

        await tunnelManager.connect()
        let finalStatus = await tunnelManager.waitUntilSettled()

        if let error = tunnelManager.lastConnectionError {
            throw PangolinIntentError.connectionFailed(error)
        }
        guard finalStatus == .connected else {
            throw PangolinIntentError.connectionFailed("Pangolin VPN didn't finish connecting.")
        }

        return .result(dialog: "Pangolin VPN: Connected.")
    }
}
