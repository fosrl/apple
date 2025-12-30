//
//  PreferencesSection.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI

enum PreferencesSection: String, CaseIterable, Identifiable {
    case preferences = "Preferences"
    case olmStatus = "Status"
    case about = "About"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .preferences:
            return "gear"
        case .olmStatus:
            return "chart.bar.doc.horizontal"
        case .about:
            return "info.circle"
        }
    }
}

