import AppIntents

struct PangolinAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    nonisolated static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectVPNIntent(),
            phrases: [
                "Connect \(.applicationName)",
                "Connect to \(.applicationName)",
                "Connect \(.applicationName) VPN",
                "Turn on \(.applicationName)",
                "Turn on \(.applicationName) VPN",
                "Enable \(.applicationName)",
                "Enable \(.applicationName) VPN",
                "Start \(.applicationName)",
                "Start \(.applicationName) VPN",
            ],
            shortTitle: "Connect VPN",
            systemImageName: "lock.shield"
        )
        AppShortcut(
            intent: DisconnectVPNIntent(),
            phrases: [
                "Disconnect \(.applicationName)",
                "Disconnect from \(.applicationName)",
                "Disconnect \(.applicationName) VPN",
                "Turn off \(.applicationName)",
                "Turn off \(.applicationName) VPN",
                "Disable \(.applicationName)",
                "Disable \(.applicationName) VPN",
                "Stop \(.applicationName)",
                "Stop \(.applicationName) VPN",
            ],
            shortTitle: "Disconnect VPN",
            systemImageName: "lock.slash"
        )
        AppShortcut(
            intent: GetVPNStatusIntent(),
            phrases: [
                "Get \(.applicationName) status",
                "Get \(.applicationName) VPN status",
                "Check \(.applicationName) status",
                "Check \(.applicationName) VPN status",
                "What is my \(.applicationName) status",
                "What is my \(.applicationName) VPN status",
                "Is \(.applicationName) connected",
                "Is \(.applicationName) VPN connected",
                "\(.applicationName) VPN status",
            ],
            shortTitle: "VPN Status",
            systemImageName: "info.circle"
        )
    }

    nonisolated static var shortcutTileColor: ShortcutTileColor { .navy }
}
