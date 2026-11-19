import Combine
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    /// App behavior on this Mac: starting at login and on-demand activation.
    case general = "General"
    /// How the tunnel connects: DNS and advanced settings, which can differ per org.
    case connection = "Connection"
    case accounts = "Accounts"
    case olmStatus = "Status"
    case about = "About"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .general:
            return "gearshape.fill"
        case .connection:
            return "network"
        case .accounts:
            return "person.crop.circle.fill"
        case .olmStatus:
            return "app.connected.to.app.below.fill"
        case .about:
            return "info.circle.fill"
        }
    }
}

/// Lets other parts of the app open Settings on a given section. The window
/// picks up the request when it appears or, if already open, right away.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()

    @Published var requestedSection: SettingsSection?
    /// Asks the Accounts section to show the login sheet.
    @Published var requestedLogin: AccountLoginRequest?
}

/// A request to show the login sheet. Each one is distinct, so the sheet is
/// presented from the request itself and always gets its hostname.
struct AccountLoginRequest: Identifiable, Equatable {
    let id = UUID()

    /// Server to log in to right away, e.g. to renew a locked account. Nil lets
    /// the user choose.
    var hostname: String?
}
