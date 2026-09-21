import SwiftUI
import WidgetKit

struct PangolinVPNWidget: Widget {
    let kind = VPNWidgetStatusStore.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PangolinVPNWidgetProvider()) { entry in
            PangolinVPNWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Pangolin VPN")
        .description("Connect or disconnect Pangolin VPN.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct PangolinVPNWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: VPNWidgetStatusSnapshot
}

struct PangolinVPNWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PangolinVPNWidgetEntry {
        PangolinVPNWidgetEntry(
            date: Date(),
            snapshot: VPNWidgetStatusSnapshot(
                statusText: "Connected",
                isConnected: true,
                isBusy: false,
                organizationName: "Acme Corp",
                serverHostname: "pangolin.example.com",
                connectedAt: Date().addingTimeInterval(-3600),
                updatedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (PangolinVPNWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PangolinVPNWidgetEntry>) -> Void) {
        let entry = currentEntry()
        let reloadDate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(reloadDate)))
    }

    private func currentEntry() -> PangolinVPNWidgetEntry {
        PangolinVPNWidgetEntry(date: Date(), snapshot: VPNWidgetStatusStore.read())
    }
}

struct PangolinVPNWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PangolinVPNWidgetEntry

    var body: some View {
        switch family {
        case .systemMedium:
            mediumLayout
        default:
            smallLayout
        }
    }

    // MARK: - Small

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                logo(size: 28)
                Spacer(minLength: 0)
                statusDot
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.snapshot.statusText)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if let org = entry.snapshot.organizationName, !org.isEmpty {
                    Text(org)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            actionLink
        }
        .padding(4)
    }

    // MARK: - Medium (2 tiles)

    private var mediumLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    logo(size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            statusDot
                            Text(entry.snapshot.statusText)
                                .font(.headline)
                                .lineLimit(1)
                        }
                        if entry.snapshot.isConnected, let connectedAt = entry.snapshot.connectedAt {
                            Text(timerInterval: connectedAt...Date.distantFuture, countsDown: false)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let org = entry.snapshot.organizationName, !org.isEmpty {
                        detailRow(label: "Organization", value: org)
                    }
                    if let host = entry.snapshot.serverHostname, !host.isEmpty {
                        detailRow(label: "Server", value: host)
                    }
                    if entry.snapshot.organizationName == nil && entry.snapshot.serverHostname == nil {
                        Text("Open Pangolin to sign in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            mediumActionLink
        }
        .padding(4)
    }

    @ViewBuilder
    private var mediumActionLink: some View {
        let disconnect = entry.snapshot.showsDisconnectButton
        Link(destination: disconnect ? VPNWidgetDeepLink.disconnect : VPNWidgetDeepLink.connect) {
            Text(disconnect ? "Disconnect" : "Connect")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.gray.opacity(0.22))
                )
        }
        .frame(maxWidth: 128, maxHeight: .infinity)
    }

    // MARK: - Shared

    private func logo(size: CGFloat) -> some View {
        Image("PangolinMark")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    private var statusDot: some View {
        Circle()
            .fill(entry.snapshot.isConnected ? Color.green : Color.secondary.opacity(0.45))
            .frame(width: 8, height: 8)
            .accessibilityLabel(entry.snapshot.statusText)
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    @ViewBuilder
    private var actionLink: some View {
        let disconnect = entry.snapshot.showsDisconnectButton
        Link(destination: disconnect ? VPNWidgetDeepLink.disconnect : VPNWidgetDeepLink.connect) {
            Text(disconnect ? "Disconnect" : "Connect")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.gray.opacity(0.22))
                )
        }
    }
}
