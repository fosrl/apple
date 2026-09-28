import Combine
import SwiftUI

enum PreferencesSection: String, CaseIterable, Identifiable {
    case preferences = "Preferences"
    case accounts = "Accounts"
    case olmStatus = "Status"
    case about = "About"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .preferences:
            return "gearshape.fill"
        case .accounts:
            return "person.crop.circle.fill"
        case .olmStatus:
            return "app.connected.to.app.below.fill"
        case .about:
            return "info.circle.fill"
        }
    }
}

/// Lets other parts of the app open Preferences on a given section. The window
/// picks up the request when it appears or, if already open, right away.
@MainActor
final class PreferencesNavigation: ObservableObject {
    static let shared = PreferencesNavigation()

    @Published var requestedSection: PreferencesSection?
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
