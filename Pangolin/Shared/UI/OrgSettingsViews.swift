import SwiftUI

/// Shown above the connection settings: whether the current org uses the settings for all
/// organizations or its own, with a button to switch, and how many settings the org's
/// administrator manages for the user's role. On macOS the button sits on the right like the
/// settings below it; on iOS there isn't room, so it gets its own row under the text.
struct OrgSettingsModeSection: View {
    @ObservedObject var configManager: ConfigManager
    @State private var confirmReset = false

    var body: some View {
        if let orgName = configManager.activeOrgName {
            Section {
                #if os(macOS)
                    HStack(alignment: .center, spacing: 12) {
                        modeText(orgName: orgName)
                        Spacer()
                        modeButton(orgName: orgName)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                #else
                    modeText(orgName: orgName)
                        .fullWidthRowSeparator()
                    modeButton(orgName: orgName)
                        .fullWidthRowSeparator()
                #endif

                let managedCount = configManager.managedPreferenceCount
                if managedCount > 0 {
                    SettingsBannerText(
                        title: ManagedSettingText.title(orgName: orgName),
                        detail: ManagedSettingText.summary(count: managedCount),
                        systemImage: "lock.fill"
                    )
                    .fullWidthRowSeparator()
                }
            }
            .alert(
                "Reset \(orgName) to settings for all organizations?",
                isPresented: $confirmReset
            ) {
                Button("Reset", role: .destructive) {
                    _ = configManager.resetActiveOrgSettings()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "\(orgName) will use your settings for all organizations again. Settings you changed for \(orgName) will be removed."
                )
            }
        }
    }
}

extension OrgSettingsModeSection {
    @ViewBuilder
    fileprivate func modeText(orgName: String) -> some View {
        if configManager.isOrgMode {
            SettingsBannerText(
                title: "\(orgName) has its own settings",
                detail: "Changes are saved only for \(orgName). Other organizations use your settings for all organizations.",
                systemImage: "building.2"
            )
        } else {
            SettingsBannerText(
                title: "\(orgName) uses your settings for all organizations",
                detail: "Changes apply to every organization. Own settings for \(orgName) start as a copy of these.",
                systemImage: "globe"
            )
        }
    }

    /// Short labels on macOS, where the button sits next to the text that explains it; fuller
    /// ones on iOS, where it's a row of its own.
    @ViewBuilder
    fileprivate func modeButton(orgName: String) -> some View {
        if configManager.isOrgMode {
            #if os(macOS)
                Button("Reset…") { confirmReset = true }
            #else
                Button("Reset to Settings for All Organizations…") { confirmReset = true }
            #endif
        } else {
            #if os(macOS)
                Button("Use Own Settings") { _ = configManager.giveActiveOrgOwnSettings() }
            #else
                Button("Use Own Settings for \(orgName)") {
                    _ = configManager.giveActiveOrgOwnSettings()
                }
            #endif
        }
    }
}

/// A banner row at the top of a settings page: an icon and bold title, with secondary detail
/// below.
struct SettingsBannerText: View {
    let title: String
    let detail: String
    let systemImage: String

    /// The icon sits on the title's line, and the detail runs underneath both at full width.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .fontWeight(.semibold)
            Text(detail)
                .foregroundColor(.secondary)
        }
        .settingsBannerFont()
    }
}

enum ManagedSettingText {
    static func title(orgName: String) -> String {
        "Managed by your administrator in \(orgName)"
    }

    static func summary(count: Int) -> String {
        let settings = count == 1 ? "1 of these settings" : "\(count) of these settings"
        let pronoun = count == 1 ? "it" : "them"
        return "Your administrator set \(settings) for your role. To change \(pronoun), contact your administrator."
    }

    static func explanation(orgName: String) -> String {
        "Your administrator in \(orgName) set this for your role. To change it, contact your administrator."
    }
}

extension View {
    /// Text size for the banners above the connection settings: the same as the settings' names,
    /// so they read as part of the page rather than fine print.
    fileprivate func settingsBannerFont() -> some View {
        #if os(macOS)
            font(.system(size: 13))
        #else
            font(.subheadline)
        #endif
    }

    /// Starts the divider under an iOS list row at the row's leading edge. By default it starts
    /// where the row's text does, which in the banner rows is after the icon, so the banner's
    /// dividers would start at different points than the button row's. No effect on macOS.
    fileprivate func fullWidthRowSeparator() -> some View {
        #if os(iOS)
            alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        #else
            self
        #endif
    }

    /// Puts a lock after a setting's name when the org's administrator manages it. The banner
    /// above the settings explains what the lock means.
    @ViewBuilder
    func managedLock(_ isManaged: Bool) -> some View {
        if isManaged {
            HStack(spacing: 4) {
                self
                Image(systemName: "lock.fill")
                    .imageScale(.small)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("Managed by your administrator")
            }
        } else {
            self
        }
    }

    /// Explains on hover why a setting the org's administrator manages can't be changed.
    @ViewBuilder
    func managedSettingHelp(_ isManaged: Bool, orgName: String) -> some View {
        if isManaged {
            help(ManagedSettingText.explanation(orgName: orgName))
        } else {
            self
        }
    }
}

extension ConfigManager {
    /// The name used in "Managed by your administrator in …".
    var managingOrgName: String {
        activeOrgName ?? "your organization"
    }

    /// How many of the settings shown in Settings the org's administrator manages. The two
    /// upstream DNS servers count as one, and only while they're shown (DNS override is on).
    var managedPreferenceCount: Int {
        guard let serverSettings else { return 0 }
        return [
            serverSettings.overrideDns != nil,
            serverSettings.tunnelDns != nil,
            serverSettings.managesUpstreamDNS && getDNSOverrideEnabled(),
            serverSettings.exitNodeTakesPrecedence != nil,
            serverSettings.mtu != nil,
        ].filter { $0 }.count
    }
}
