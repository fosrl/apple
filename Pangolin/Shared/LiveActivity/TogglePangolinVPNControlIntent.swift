import AppIntents

/// Control Center toggle intent. Writes a pending action and opens the app
/// (`openAppWhenRun`); the app performs connect/disconnect via TunnelManager.
struct TogglePangolinVPNControlIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Pangolin"
    static var description = IntentDescription("Connect or disconnect Pangolin.")
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = false

    @Parameter(title: "Connected")
    var value: Bool

    init() {}

    init(value: Bool) {
        self.value = value
    }

    func perform() async throws -> some IntentResult {
        VPNWidgetPendingAction.set(value ? .connect : .disconnect)
        return .result()
    }
}
