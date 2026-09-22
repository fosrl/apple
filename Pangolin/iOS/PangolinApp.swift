import SwiftUI
import os.log

@main
struct PangolinApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var configManager = ConfigManager()
    @StateObject private var secretManager = SecretManager()
    @StateObject private var accountManager = AccountManager()
    @StateObject private var apiClient: APIClient
    @StateObject private var authManager: AuthManager
    @StateObject private var tunnelManager: TunnelManager
    @StateObject private var onboardingStateManager: OnboardingStateManager
    @StateObject private var onboardingViewModel: OnboardingViewModel

    init() {
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

        // Expose the manager graph to App Intents (Shortcuts), which run in this
        // process but outside the SwiftUI view hierarchy.
        AppDependencies.shared.configure(
            tunnelManager: tunnelMgr, authManager: authMgr, accountManager: accountMgr)

        let onboardingState = OnboardingStateManager()
        let onboardingVM = OnboardingViewModel(
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
        WindowGroup {
            Group {
                if authManager.isInitializing {
                    // Show loading state during initialization
                    VStack {
                        ProgressView()
                        Text("Loading...")
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                    }
                } else if authManager.isAuthenticated {
                    // Main view with tunnel controls and settings
                    MainView(
                        configManager: configManager,
                        authManager: authManager,
                        accountManager: accountManager,
                        tunnelManager: tunnelManager,
                        apiClient: apiClient
                    )
                } else {
                    // Show login view when not authenticated
                    LoginView(
                        authManager: authManager,
                        accountManager: accountManager,
                        configManager: configManager,
                        apiClient: apiClient
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                Task {
                    await authManager.initialize()
                    await onboardingViewModel.refreshPages()
                    await tunnelManager.refreshProviderConfigurationIfOnDemandEnabled()
                    await performPendingVPNWidgetActionIfNeeded()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await tunnelManager.refreshProviderConfigurationIfOnDemandEnabled()
                    await performPendingVPNWidgetActionIfNeeded()
                }
            }
            .onOpenURL { url in
                Task { await handleVPNWidgetURL(url) }
            }
            .fullScreenCover(isPresented: $onboardingViewModel.isPresenting) {
                OnboardingFlowView(viewModel: onboardingViewModel)
            }
        }
    }

    @MainActor
    private func handleVPNWidgetURL(_ url: URL) async {
        guard let action = VPNWidgetDeepLink.action(from: url) else { return }
        await performVPNWidgetAction(action)
    }

    @MainActor
    private func performPendingVPNWidgetActionIfNeeded() async {
        guard let action = VPNWidgetPendingAction.take() else { return }
        await performVPNWidgetAction(action)
    }

    @MainActor
    private func performVPNWidgetAction(_ action: VPNWidgetDeepLink.Action) async {
        await authManager.initialize()

        switch action {
        case .connect:
            guard authManager.isAuthenticated, authManager.currentOrg != nil else { return }
            await tunnelManager.connect()
        case .disconnect:
            await tunnelManager.disconnect()
        }
    }

    @MainActor
    private func performVPNWidgetAction(_ action: VPNWidgetPendingAction) async {
        switch action {
        case .connect:
            await performVPNWidgetAction(VPNWidgetDeepLink.Action.connect)
        case .disconnect:
            await performVPNWidgetAction(VPNWidgetDeepLink.Action.disconnect)
        }
    }
}
