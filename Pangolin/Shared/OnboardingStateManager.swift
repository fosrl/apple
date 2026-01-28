import Foundation
import Combine

final class OnboardingStateManager: ObservableObject {
    private enum Keys {
        static let hasSeenWelcome = "net.pangolin.Pangolin.Onboarding.hasSeenWelcome"
        static let hasAcknowledgedPrivacy =
            "net.pangolin.Pangolin.Onboarding.hasAcknowledgedPrivacy"
        static let hasCompletedVPNInstallOnboarding =
            "net.pangolin.Pangolin.Onboarding.hasCompletedVPNInstallOnboarding"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Whether the user has seen the initial "Welcome to Pangolin" screen.
    var hasSeenWelcome: Bool {
        get { userDefaults.bool(forKey: Keys.hasSeenWelcome) }
        set { userDefaults.set(newValue, forKey: Keys.hasSeenWelcome) }
    }

    /// Whether the user has acknowledged the privacy / data collection information.
    var hasAcknowledgedPrivacy: Bool {
        get { userDefaults.bool(forKey: Keys.hasAcknowledgedPrivacy) }
        set { userDefaults.set(newValue, forKey: Keys.hasAcknowledgedPrivacy) }
    }

    /// Whether the user has gone through the VPN install onboarding step at least once.
    var hasCompletedVPNInstallOnboarding: Bool {
        get { userDefaults.bool(forKey: Keys.hasCompletedVPNInstallOnboarding) }
        set { userDefaults.set(newValue, forKey: Keys.hasCompletedVPNInstallOnboarding) }
    }

    func markWelcomeSeen() {
        hasSeenWelcome = true
    }

    func markPrivacyAcknowledged() {
        hasAcknowledgedPrivacy = true
    }

    func markCompletedVPNInstallOnboarding() {
        hasCompletedVPNInstallOnboarding = true
    }
}

