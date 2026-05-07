import SwiftUI
import AppKit

// Note: this view is hosted inside an AppKit-managed NSWindow created by
// AppWindowsController. Window-level configuration (styleMask, identifier,
// title, button visibility, activation policy) is handled there, so this view
// only owns the SwiftUI content. Previous SwiftUI-based window manipulation
// (configureWindow, hideMenuBarItems, PreferencesWindowAccessor) was removed
// because it caused a layout-cycle crash inside NavigationSplitView on macOS 26.

struct PreferencesWindow: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager
    @State private var selectedSection: PreferencesSection = .preferences

    var body: some View {
        NavigationSplitView {
            PreferencesSidebar(selectedSection: $selectedSection)
        } detail: {
            PreferencesDetailView(
                selectedSection: selectedSection,
                configManager: configManager,
                tunnelManager: tunnelManager
            )
        }
        .onChange(of: selectedSection) { _, _ in
            updateWindowTitle()
        }
        .onAppear {
            updateWindowTitle()
        }
    }

    private func updateWindowTitle() {
        if let window = NSApplication.shared.windows.first(where: {
            $0.identifier?.rawValue == "preferences"
        }) {
            window.title = selectedSection.rawValue
        }
    }
}

// MARK: - Sidebar

struct PreferencesSidebar: View {
    @Binding var selectedSection: PreferencesSection

    var body: some View {
        List(PreferencesSection.allCases, selection: $selectedSection) { section in
            Label(section.rawValue, systemImage: section.icon)
                .tag(section)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 200)
    }
}

// MARK: - Detail View

struct PreferencesDetailView: View {
    let selectedSection: PreferencesSection
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager

    var body: some View {
        Group {
            switch selectedSection {
            case .preferences:
                PreferencesContentView(configManager: configManager)
            case .olmStatus:
                OLMStatusContentView(olmStatusManager: tunnelManager.olmStatusManager)
            case .about:
                AboutContentView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
