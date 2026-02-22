import AppKit
import Sparkle
import SwiftUI
import os.log

#if os(macOS)
struct MenuBarIconView: View {
    @ObservedObject var tunnelManager: TunnelManager

    private var tunnelStatus: TunnelStatus {
        tunnelManager.status
    }

    private var isInIntermediateState: Bool {
        switch tunnelStatus {
        case .starting, .registering:
            return true
        default:
            return false
        }
    }

    var body: some View {
        if tunnelStatus == .connected {
            Image("MenuBarIcon")
                .renderingMode(.template)
        } else if isInIntermediateState {
            AnimatedLoadingIcon()
        } else {
            Image("MenuBarIconDimmed")
                .renderingMode(.template)
        }
    }
}

struct AnimatedLoadingIcon: View {
    @State private var currentFrame = 1

    private let frameNames = ["MenuBarIconLoading1", "MenuBarIconLoading2", "MenuBarIconLoading3"]

    var body: some View {
        Image(frameNames[currentFrame - 1])
            .renderingMode(.template)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)  // 0.3 seconds
                    currentFrame = (currentFrame % 3) + 1
                }
            }
    }
}

@main
struct PangolinApp: App {
    @StateObject private var configManager = ConfigManager()
    @StateObject private var secretManager = SecretManager()
    @StateObject private var accountManager = AccountManager()
    @StateObject private var apiClient: APIClient
    @StateObject private var authManager: AuthManager
    @StateObject private var tunnelManager: TunnelManager
    @StateObject private var onboardingStateManager: OnboardingStateManager
    @StateObject private var onboardingViewModel: MacOnboardingViewModel

    private let updaterController: SPUStandardUpdaterController

    init() {
        // Initialize Sparkle updater
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        let configMgr = ConfigManager()
        let secretMgr = SecretManager()
        let accountMgr = AccountManager()

        let activeAccount = accountMgr.activeAccount

        let hostname = activeAccount?.hostname ?? ConfigManager.defaultHostname
        let token =
            activeAccount.flatMap { acct in
                secretMgr.getSessionToken(userId: acct.userId)
            } ?? ""

        let client = APIClient(baseURL: hostname, sessionToken: token)
        let authMgr = AuthManager(
            apiClient: client,
            configManager: configMgr,
            accountManager: accountMgr,
            secretManager: secretMgr,
        )
        let tunnelMgr = TunnelManager(
            configManager: configMgr,
            accountManager: accountMgr,
            secretManager: secretMgr,
            authManager: authMgr,
        )

        // Set tunnel manager reference in auth manager for org switching
        authMgr.tunnelManager = tunnelMgr

        let onboardingState = OnboardingStateManager()
        let onboardingVM = MacOnboardingViewModel(
            onboardingState: onboardingState,
            tunnelManager: tunnelMgr
        )

        _configManager = StateObject(wrappedValue: configMgr)
        _secretManager = StateObject(wrappedValue: secretMgr)
        _accountManager = StateObject(wrappedValue: accountMgr)
        _apiClient = StateObject(wrappedValue: client)
        _authManager = StateObject(wrappedValue: authMgr)
        _tunnelManager = StateObject(wrappedValue: tunnelMgr)
        _onboardingStateManager = StateObject(wrappedValue: onboardingState)
        _onboardingViewModel = StateObject(wrappedValue: onboardingVM)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                configManager: configManager,
                accountManager: accountManager,
                apiClient: apiClient,
                authManager: authManager,
                tunnelManager: tunnelManager,
                updater: updaterController.updater,
                onboardingViewModel: onboardingViewModel
            )
            .onAppear {
                // Set activation policy to accessory (menu bar only) when not showing onboarding
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard !onboardingViewModel.isPresenting, NSApp.activationPolicy() != .accessory else { return }
                    NSApp.setActivationPolicy(.accessory)
                }

                Task {
                    await authManager.initialize()
                }
            }
        } label: {
            MenuBarIconView(tunnelManager: tunnelManager)
        }

        // Main Window (Login)
        WindowGroup("Pangolin", id: "main") {
            LoginView(
                authManager: authManager,
                accountManager: accountManager,
                configManager: configManager,
                apiClient: apiClient
            )
            .handlesExternalEvents(preferring: ["main"], allowing: ["main"])
            .onAppear {
                // Ensure window has correct identifier
                DispatchQueue.main.async {
                    if let window = NSApplication.shared.windows.first(where: {
                        $0.title == "Pangolin"
                    }) {
                        window.identifier = NSUserInterfaceItemIdentifier("main")
                    }
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 440, height: 300)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Onboarding Window
        WindowGroup("Pangolin Setup", id: "onboarding") {
            MacOnboardingFlowView(viewModel: onboardingViewModel)
                .handlesExternalEvents(preferring: ["onboarding"], allowing: ["onboarding"])
        }
        .defaultSize(width: 480, height: 420)
        .windowResizability(.contentSize)

        // Preferences Window
        WindowGroup("Preferences", id: "preferences") {
            PreferencesWindow(
                configManager: configManager,
                tunnelManager: tunnelManager
            )
            .handlesExternalEvents(preferring: ["preferences"], allowing: ["preferences"])
        }
        .defaultSize(width: 800, height: 600)
        .windowResizability(.contentSize)
        .commands {
            // Hide all menu bar items for preferences window
            CommandGroup(replacing: .appInfo) {}
            CommandGroup(replacing: .appSettings) {}
            CommandGroup(replacing: .appTermination) {}
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .pasteboard) {}
            CommandGroup(replacing: .sidebar) {}
            CommandGroup(replacing: .textEditing) {}
            CommandGroup(replacing: .textFormatting) {}
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(replacing: .undoRedo) {}
        }
    }
}
#endif
