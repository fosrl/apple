import SwiftUI

/// Whether the current org is using the global settings or its own, shown above the settings.
struct OrgSettingsModeSection: View {
    @ObservedObject var configManager: ConfigManager

    var body: some View {
        if let orgName = configManager.activeOrgName {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        configManager.isOrgMode
                            ? "\(orgName) is using its own settings."
                            : "\(orgName) is using your global settings."
                    )
                    if configManager.serverSettings != nil {
                        Text("Settings set by your organization can't be changed.")
                            .foregroundColor(.secondary)
                    }
                }
                .font(.footnote)
            }
        }
    }
}

/// Switches the current org back to the global settings, shown below the settings.
struct OrgSettingsResetSection: View {
    @ObservedObject var configManager: ConfigManager

    var body: some View {
        if configManager.isOrgMode, let orgName = configManager.activeOrgName {
            Section {
                Button("Use Global Settings for \(orgName)") {
                    _ = configManager.resetActiveOrgSettings()
                }
            }
        }
    }
}

/// Asks whether a setting change applies everywhere or just to the current org. Settings apply
/// as soon as they change, so this is asked when a setting changes rather than on a save button.
struct SettingsScopePrompt: ViewModifier {
    @ObservedObject var configManager: ConfigManager
    @Binding var pendingChange: ((SettingsScope) -> Void)?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Apply this change to all organizations, or only to \(configManager.activeOrgName ?? "this organization")?",
            isPresented: Binding(
                get: { pendingChange != nil },
                set: { if !$0 { pendingChange = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingChange
        ) { change in
            Button("All Organizations") { change(.global) }
            Button("Only \(configManager.activeOrgName ?? "This Organization")") { change(.org) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

extension ConfigManager {
    /// Runs a change right away if its scope is already known, or hands it to `ask` so the user
    /// can pick one with `SettingsScopePrompt`.
    func applyScoped(
        _ change: @escaping (SettingsScope) -> Void,
        ask: (@escaping (SettingsScope) -> Void) -> Void
    ) {
        if let scope = knownScope {
            change(scope)
        } else {
            ask(change)
        }
    }
}
