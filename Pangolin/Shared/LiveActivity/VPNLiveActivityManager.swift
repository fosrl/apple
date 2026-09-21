#if os(iOS)
    import ActivityKit
    import Foundation
    import os.log
    import UIKit

    @MainActor
    final class VPNLiveActivityManager {
        static let shared = VPNLiveActivityManager()

        private var activity: Activity<PangolinVPNAttributes>?
        private var connectedAt: Date?
        private var resignObserver: NSObjectProtocol?
        private var activeObserver: NSObjectProtocol?
        /// Org to use once we're allowed to start (typically after leaving the foreground).
        private var pendingStartOrganizationName: String?
        private var isConnected = false

        private let logger = OSLog(
            subsystem: Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin",
            category: "VPNLiveActivity"
        )

        private init() {
            // Starting while foreground shows a banner that later morphs into a shared
            // Dynamic Island (jitter when Music/etc. already owns the island). Defer the
            // Activity.request until resign-active so it lands directly in the island.
            resignObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    VPNLiveActivityManager.shared.startPendingIfNeeded()
                }
            }

            activeObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    // Retry a failed background-adjacent start once we're active again
                    // only if still connected and still missing an activity — still defer
                    // the actual request until the next resign.
                    VPNLiveActivityManager.shared.adoptExistingActivityIfNeeded()
                }
            }
        }

        func handleStatusChange(
            status: TunnelStatus,
            organizationName: String?
        ) {
            switch status {
            case .connected:
                isConnected = true
                let org = organizationName?.isEmpty == false ? organizationName! : "Pangolin"
                pendingStartOrganizationName = org
                // If we're already inactive/background, start immediately.
                if UIApplication.shared.applicationState != .active {
                    startPendingIfNeeded()
                }
            // else: wait for willResignActive so the island presentation isn't a morph
            // from an in-app banner into a crowded Dynamic Island.
            case .disconnected:
                isConnected = false
                pendingStartOrganizationName = nil
                endActivity()
            case .starting, .registering:
                break
            }
        }

        func reconcileOnLaunch(
            status: TunnelStatus,
            organizationName: String?
        ) {
            adoptExistingActivityIfNeeded()

            handleStatusChange(
                status: status,
                organizationName: organizationName
            )
        }

        private func adoptExistingActivityIfNeeded() {
            guard activity == nil else { return }
            activity = Activity<PangolinVPNAttributes>.activities.first
            if let existing = activity {
                connectedAt = existing.content.state.connectedAt
            }
        }

        private func startPendingIfNeeded() {
            guard isConnected,
                let organizationName = pendingStartOrganizationName
            else { return }
            startActivity(organizationName: organizationName)
        }

        private func startActivity(organizationName: String) {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                os_log("Live Activities are disabled", log: logger, type: .info)
                return
            }

            adoptExistingActivityIfNeeded()

            // Already running — leave content alone. ActivityKit updates redraw the
            // Dynamic Island and cause visible jitter even when values barely change.
            if activity != nil {
                pendingStartOrganizationName = nil
                return
            }

            let startDate = Date()
            connectedAt = startDate
            let attributes = PangolinVPNAttributes(organizationName: organizationName)
            let state = PangolinVPNAttributes.ContentState(
                statusText: TunnelStatus.connected.displayText,
                connectedAt: startDate
            )

            do {
                activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(
                        state: state,
                        staleDate: nil,
                        // Lowest allowed score — yield the primary island slot to others.
                        relevanceScore: 0
                    ),
                    pushType: nil
                )
                pendingStartOrganizationName = nil
                os_log(
                    "Live Activity started: %{public}@", log: logger, type: .info,
                    activity?.id ?? "")
            } catch {
                // Keep pending so a later resign-active can retry.
                os_log(
                    "Failed to start Live Activity: %{public}@", log: logger, type: .error,
                    error.localizedDescription)
            }
        }

        private func endActivity() {
            connectedAt = nil
            adoptExistingActivityIfNeeded()
            let activities: [Activity<PangolinVPNAttributes>]
            if let activity {
                activities = [activity]
            } else {
                activities = Array(Activity<PangolinVPNAttributes>.activities)
            }
            self.activity = nil

            guard !activities.isEmpty else { return }

            let finalState = PangolinVPNAttributes.ContentState(
                statusText: TunnelStatus.disconnected.displayText,
                connectedAt: Date()
            )

            Task {
                for activity in activities {
                    await activity.end(
                        ActivityContent(
                            state: finalState, staleDate: nil, relevanceScore: 0),
                        dismissalPolicy: .immediate
                    )
                }
                os_log("Live Activity ended", log: logger, type: .info)
            }
        }
    }
#endif
