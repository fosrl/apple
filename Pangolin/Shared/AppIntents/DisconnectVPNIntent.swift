import AppIntents

nonisolated struct DisconnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect Pangolin VPN"
    static var description = IntentDescription("Disables the Pangolin VPN connection.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (tunnelManager, _, _) = try AppDependencies.shared.requireManagers()

        await tunnelManager.disconnect()
        let finalStatus = await tunnelManager.waitUntilSettled()

        return .result(dialog: "Pangolin VPN: \(finalStatus.displayText).")
    }
}
