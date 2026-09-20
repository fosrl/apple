import AppIntents

enum PangolinIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notLoggedIn
    case noOrganizationSelected
    case appUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notLoggedIn:
            return "Please open Pangolin and log in first."
        case .noOrganizationSelected:
            return "Please open Pangolin and select an organization first."
        case .appUnavailable:
            return "Pangolin isn't ready yet. Please open the app and try again."
        }
    }
}
