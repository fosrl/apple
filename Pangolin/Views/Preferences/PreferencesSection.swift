//
//  PreferencesSection.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI

enum PreferencesSection: String, CaseIterable, Identifiable {
    case preferences = "Preferences"
    case olmStatus = "OLM Status"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .preferences:
            return "gear"
        case .olmStatus:
            return "chart.bar.doc.horizontal"
        }
    }
}

