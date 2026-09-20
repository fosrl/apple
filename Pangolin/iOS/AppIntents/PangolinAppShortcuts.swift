import AppIntents

struct PangolinAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectVPNIntent(),
            phrases: [
                "Connect \(.applicationName)",
                "Turn on \(.applicationName) VPN",
                "Enable \(.applicationName) VPN",
            ],
            shortTitle: "Connect VPN",
            systemImageName: "lock.shield"
        )
        AppShortcut(
            intent: DisconnectVPNIntent(),
            phrases: [
                "Disconnect \(.applicationName)",
                "Turn off \(.applicationName) VPN",
                "Disable \(.applicationName) VPN",
            ],
            shortTitle: "Disconnect VPN",
            systemImageName: "lock.slash"
        )
        AppShortcut(
            intent: GetVPNStatusIntent(),
            phrases: [
                "Get \(.applicationName) VPN status",
                "Check \(.applicationName) VPN status",
            ],
            shortTitle: "VPN Status",
            systemImageName: "info.circle"
        )
    }

    static var shortcutTileColor: ShortcutTileColor = .navy
}
