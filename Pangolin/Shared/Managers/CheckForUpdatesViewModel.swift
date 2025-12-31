//
//  CheckForUpdatesViewModel.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/20/25.
//

import Foundation
import Combine

#if os(macOS)
import Sparkle
#endif

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    #if os(macOS)
    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
    #else
    init(updater: Any) {
        // iOS doesn't use Sparkle - updates are managed through App Store
        canCheckForUpdates = false
    }
    #endif
}

