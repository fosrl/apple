import ActivityKit
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
                    PangolinLiveActivityLogo(size: 44)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.organizationName)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                        .symbolRenderingMode(.hierarchical)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(context.attributes.organizationName)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(spacing: 8) {
                PangolinLiveActivityLogo(size: 28)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    ConnectedIndicatorDot(size: 8)
                    Text(context.state.statusText)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
    }
}

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<PangolinVPNAttributes>

    var body: some View {
        HStack(spacing: 12) {
            PangolinLiveActivityLogo(size: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ConnectedIndicatorDot(size: 8)
                    Text(context.state.statusText)
                        .font(.headline)
                    Spacer()
                    Text(
                        timerInterval: context.state.connectedAt...Date.distantFuture,
                        countsDown: false
                    )
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                }

                Text(context.attributes.organizationName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
        }
        .padding(16)
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
