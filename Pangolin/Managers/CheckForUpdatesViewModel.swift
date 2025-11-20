//
//  CheckForUpdatesViewModel.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/20/25.
//

import Foundation
import Sparkle
import Combine

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

