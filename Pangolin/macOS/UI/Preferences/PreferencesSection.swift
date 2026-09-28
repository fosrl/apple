import Combine
import SwiftUI

enum PreferencesSection: String, CaseIterable, Identifiable {
    case preferences = "Preferences"
    case olmStatus = "Status"
    case about = "About"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .preferences:
            return "gearshape.fill"
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
}
