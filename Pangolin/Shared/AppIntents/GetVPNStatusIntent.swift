import AppIntents

nonisolated struct GetVPNStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Pangolin Status"
    static var description = IntentDescription(
        "Returns whether the Pangolin VPN is connected, along with the active organization and server."
    )
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<VPNStatusEntity>
        & ProvidesDialog
    {
        let (tunnelManager, authManager, accountManager) =
            try AppDependencies.shared.requireManagers()

        await AppDependencies.shared.ensureAuthLoaded()

        let entity = VPNStatusEntity(
            isConnected: tunnelManager.status == .connected,
            statusText: tunnelManager.status.displayText,
            organizationName: authManager.currentOrg?.name,
            serverHostname: accountManager.activeAccount?.hostname
        )

        return .result(value: entity, dialog: "Pangolin: \(entity.statusText).")
    }
}
