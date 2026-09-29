import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct PangolinVPNLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PangolinVPNAttributes.self) { context in
            LiveActivityContentView(context: context)
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(URL(string: "pangolin://"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        PangolinLiveActivityLogo(size: 44)
                        Spacer(minLength: 0)
                    }
                    .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        IslandPowerButton(isOn: context.state.statusText == "Connected")
                        Spacer(minLength: 0)
                    }
                    .frame(maxHeight: .infinity)
                }
            } compactLeading: {
                // Same footprint as minimal so compact↔minimal morphs don't reflow the logo.
                PangolinLiveActivityLogo(size: Self.islandLogoSize)
                    .frame(width: Self.islandSlotSize, height: Self.islandSlotSize)
            } compactTrailing: {
                Color.clear
                    .frame(width: Self.islandSlotSize, height: Self.islandSlotSize)
            } minimal: {
                PangolinLiveActivityLogo(size: Self.islandLogoSize)
                    .frame(width: Self.islandSlotSize, height: Self.islandSlotSize)
            }
            .widgetURL(URL(string: "pangolin://"))
        }
        .supplementalActivityFamilies([.small])
    }

    /// Keep compact + minimal identical so morphs don't reflow the logo.
    private static let islandLogoSize: CGFloat = 20
    private static let islandSlotSize: CGFloat = 28
}

private struct LiveActivityContentView: View {
    @Environment(\.activityFamily) private var activityFamily
    let context: ActivityViewContext<PangolinVPNAttributes>

    var body: some View {
        switch activityFamily {
        case .small:
            WatchLiveActivityView(context: context)
                .activityBackgroundTint(nil)
        case .medium:
            LockScreenLiveActivityView(context: context)
                .activityBackgroundTint(.clear)
        @unknown default:
            LockScreenLiveActivityView(context: context)
                .activityBackgroundTint(.clear)
        }
    }
}

/// Apple Watch Smart Stack layout.
private struct WatchLiveActivityView: View {
    let context: ActivityViewContext<PangolinVPNAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            PangolinLiveActivityLogo(size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pangolin Status")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    ConnectedIndicatorDot(size: 8)
                    Text(context.state.statusText)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<PangolinVPNAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            PangolinLiveActivityLogo(size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pangolin Status")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    ConnectedIndicatorDot(size: 8)
                    Text(context.state.statusText)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            IslandPowerButton(isOn: context.state.statusText == "Connected")
        }
        .padding(16)
    }
}

private struct IslandPowerButton: View {
    let isOn: Bool

    var body: some View {
        Button(intent: TogglePangolinVPNControlIntent(value: !isOn)) {
            Image(systemName: "power")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isOn ? Color.green : Color.white.opacity(0.72))
                .frame(width: 44, height: 44)
                .background {
                    Circle()
                        .fill(isOn ? Color.green.opacity(0.18) : Color.white.opacity(0.08))
                }
                .overlay {
                    Circle()
                        .strokeBorder(
                            isOn ? Color.green : Color.white.opacity(0.35),
                            lineWidth: 1.5
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Connected" : "Disconnected")
        .accessibilityHint(isOn ? "Disconnect Pangolin" : "Connect Pangolin")
    }
}

private struct ConnectedIndicatorDot: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: size, height: size)
            .accessibilityLabel("Connected")
    }
}

private struct PangolinLiveActivityLogo: View {
    let size: CGFloat

    var body: some View {
        Image("PangolinMark")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .contentTransition(.identity)
            .transaction { $0.animation = nil }
    }
}
