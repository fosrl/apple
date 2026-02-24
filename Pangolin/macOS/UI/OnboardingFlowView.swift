import SwiftUI
import AppKit
import Combine

/// macOS onboarding view model: welcome → privacy → system extension → VPN profile.
final class MacOnboardingViewModel: ObservableObject {
    @Published var isPresenting: Bool = false
    @Published var isInstallingSystemExtension: Bool = false
    @Published var isInstallingVPN: Bool = false
    @Published var currentIndex: Int = 0

    /// Prevents opening multiple onboarding windows when the menu bar view's task runs repeatedly.
    var hasOpenedOnboardingWindowThisSession: Bool = false

    @Published private(set) var hasSeenWelcome: Bool
    @Published private(set) var hasAcknowledgedPrivacy: Bool
    @Published private(set) var hasCompletedSystemExtension: Bool
    @Published private(set) var vpnInstalled: Bool = false

    private let onboardingState: OnboardingStateManager
    private let tunnelManager: TunnelManager
    private let accountManager: AccountManager

    private var hasNoAccounts: Bool {
        accountManager.accounts.isEmpty
    }

    @MainActor
    init(onboardingState: OnboardingStateManager, tunnelManager: TunnelManager, accountManager: AccountManager) {
        self.onboardingState = onboardingState
        self.tunnelManager = tunnelManager
        self.accountManager = accountManager
        self.hasSeenWelcome = onboardingState.hasSeenWelcome
        self.hasAcknowledgedPrivacy = onboardingState.hasAcknowledgedPrivacy
        self.hasCompletedSystemExtension = onboardingState.hasCompletedSystemExtensionOnboarding
    }

    /// Re-computes which pages should be visible based on local state and VPN configuration.
    @MainActor
    func refreshPages() async {
        hasSeenWelcome = onboardingState.hasSeenWelcome
        hasAcknowledgedPrivacy = onboardingState.hasAcknowledgedPrivacy
        hasCompletedSystemExtension = onboardingState.hasCompletedSystemExtensionOnboarding
        vpnInstalled = await tunnelManager.isVPNProfileInstalled()

        let needsWelcome = !hasSeenWelcome
        let needsPrivacy = !hasAcknowledgedPrivacy
        let needsSystemExtension = !hasCompletedSystemExtension
        let needsVPN = !vpnInstalled

        isPresenting = needsWelcome || needsPrivacy || needsSystemExtension || needsVPN

        if isPresenting {
            if needsWelcome {
                currentIndex = 0
            } else if needsPrivacy {
                currentIndex = 1
            } else if needsSystemExtension {
                currentIndex = 2
            } else {
                currentIndex = 3
            }
        }
    }

    @MainActor
    func handleWelcomeContinue() {
        onboardingState.markWelcomeSeen()
        hasSeenWelcome = true
        goToNextPage()
    }

    @MainActor
    func handlePrivacyAcknowledge() {
        onboardingState.markPrivacyAcknowledged()
        hasAcknowledgedPrivacy = true
        goToNextPage()
    }

    @MainActor
    func handleSystemExtensionInstallTapped() async {
        guard !isInstallingSystemExtension else { return }
        isInstallingSystemExtension = true
        defer { isInstallingSystemExtension = false }

        let installed = await tunnelManager.installSystemExtensionIfNeeded()
        if installed {
            hasCompletedSystemExtension = true
            onboardingState.markSystemExtensionOnboardingComplete()
            goToNextPage()
        }
    }

    @MainActor
    func handleSystemExtensionNext() {
        goToNextPage()
    }

    @MainActor
    func handleVPNInstallTapped() async {
        guard !isInstallingVPN else { return }
        isInstallingVPN = true
        defer { isInstallingVPN = false }

        let installed = await tunnelManager.ensureVPNProfileInstalled()
        if installed {
            vpnInstalled = true
            onboardingState.markCompletedVPNInstallOnboarding()
        }
    }

    @MainActor
    func handleDoneTapped() {
        // On VPN step with no accounts: show completion page instead of closing
        if currentIndex == 3, vpnInstalled, hasNoAccounts {
            currentIndex = 4
            return
        }
        isPresenting = false
        hasOpenedOnboardingWindowThisSession = false
        closeOnboardingWindow()
    }

    @MainActor
    func goToNextPage() {
        currentIndex = min(currentIndex + 1, 4)
    }

    @MainActor
    func goToPreviousPage() {
        currentIndex = max(0, currentIndex - 1)
    }

    @MainActor
    func handleCompletionDoneTapped() {
        isPresenting = false
        hasOpenedOnboardingWindowThisSession = false
        closeOnboardingWindow()
    }

    @MainActor
    private func closeOnboardingWindow() {
        if let window = NSApplication.shared.windows.first(where: { $0.title == "CNDF-VPN Setup" }) {
            window.close()
        }
    }
}

struct MacOnboardingFlowView: View {
    @ObservedObject var viewModel: MacOnboardingViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var stepCount: Int { viewModel.currentIndex == 4 ? 5 : 4 }

    /// Matches LoginView background: dark #161618, light #FDFDFD
    private var windowBackgroundColor: Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 0x16/255.0, green: 0x16/255.0, blue: 0x18/255.0, opacity: 1)
            : Color(.sRGB, red: 0xFD/255.0, green: 0xFD/255.0, blue: 0xFD/255.0, opacity: 1)
    }

    var body: some View {
        ZStack {
            windowBackgroundColor
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Step indicator
                HStack(spacing: 6) {
                    ForEach(0..<stepCount, id: \.self) { index in
                        Circle()
                            .fill(index <= viewModel.currentIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                    Spacer()
                    Text("Step \(viewModel.currentIndex + 1) of \(stepCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

                // Page content
                Group {
                    switch viewModel.currentIndex {
                    case 0:
                        MacOnboardingWelcomePageContent(isCompleted: viewModel.hasSeenWelcome)
                    case 1:
                        MacOnboardingPrivacyPageContent(isAcknowledged: viewModel.hasAcknowledgedPrivacy)
                    case 2:
                        MacOnboardingSystemExtensionPageContent(
                            isCompleted: viewModel.hasCompletedSystemExtension,
                            isInstalling: viewModel.isInstallingSystemExtension
                        )
                    case 3:
                        MacOnboardingVPNPageContent(
                            vpnInstalled: viewModel.vpnInstalled,
                            isInstalling: viewModel.isInstallingVPN
                        )
                    default:
                        MacOnboardingCompletionPageContent()
                    }
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Footer: confirmation text (bottom left) ↔ Back + primary action (bottom right)
                HStack(alignment: .center) {
                    footerConfirmationText
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if viewModel.currentIndex > 0 && viewModel.currentIndex < 4 {
                        Button("Back") {
                            viewModel.goToPreviousPage()
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                    primaryButton
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .padding(.top, 16)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(windowBackgroundColor)
        .background(
            OnboardingWindowAccessor { window in
                configureOnboardingWindow(window)
            }
        )
        .onAppear {
            DispatchQueue.main.async {
                NSApplication.shared.windows.first { $0.title == "CNDF-VPN Setup" }?.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func configureOnboardingWindow(_ window: NSWindow) {
        var styleMask = window.styleMask
        styleMask.remove([.miniaturizable, .resizable])
        styleMask.insert([.titled, .closable])
        window.styleMask = styleMask
        window.styleMask.remove(.resizable)

        if let minimizeButton = window.standardWindowButton(.miniaturizeButton) {
            minimizeButton.isHidden = true
        }
        if let zoomButton = window.standardWindowButton(.zoomButton) {
            zoomButton.isHidden = true
        }
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.isHidden = false
        }

        window.isMovableByWindowBackground = false
    }

    @ViewBuilder
    private var footerConfirmationText: some View {
        let (show, message) = footerConfirmationState
        if show {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(message)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Spacer()
                .frame(maxWidth: .infinity)
        }
    }

    private var footerConfirmationState: (show: Bool, message: String) {
        switch viewModel.currentIndex {
        case 0:
            return (viewModel.hasSeenWelcome, "You've completed this step")
        case 1:
            return (viewModel.hasAcknowledgedPrivacy, "You've already confirmed this step")
        case 2:
            return (viewModel.hasCompletedSystemExtension, "System extension installed")
        case 3:
            return (viewModel.vpnInstalled, "VPN configuration installed")
        default:
            return (false, "")
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch viewModel.currentIndex {
        case 0:
            Button("Next") {
                viewModel.handleWelcomeContinue()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case 1:
            Button(viewModel.hasAcknowledgedPrivacy ? "Next" : "I understand") {
                viewModel.handlePrivacyAcknowledge()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case 2:
            if viewModel.hasCompletedSystemExtension {
                Button("Next") {
                    viewModel.handleSystemExtensionNext()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Install System Extension") {
                    Task { await viewModel.handleSystemExtensionInstallTapped() }
                }
                .buttonStyle(.borderedProminent)
            }
        case 3:
            if viewModel.vpnInstalled {
                Button("Done") {
                    viewModel.handleDoneTapped()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Install") {
                    Task { await viewModel.handleVPNInstallTapped() }
                }
                .buttonStyle(.borderedProminent)
            }
        default:
            Button("Done") {
                viewModel.handleCompletionDoneTapped()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Welcome Page (content only)

private struct MacOnboardingWelcomePageContent: View {
    let isCompleted: Bool

    var body: some View {
        VStack {
            Spacer(minLength: 24)

            Image("PangolinLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 60)
                .padding(.bottom, 24)

            Text("Welcome to CNDF-VPN")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            Text(
                "CNDF-VPN securely connects your devices to your private networks, so you can safely access internal apps and resources from anywhere."
            )
            .font(.body)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

            Spacer()

            if let docsURL = URL(string: "https://docs.pangolin.net/about/how-pangolin-works") {
                HStack(spacing: 4) {
                    Text("New to CNDF-VPN?")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Link("Learn more.", destination: docsURL)
                        .font(.caption)
                }
                .padding(.top, 8)
            }
            Spacer().frame(minHeight: 16)
        }
    }
}

// MARK: - Privacy Page (content only)

private struct MacOnboardingPrivacyPageContent: View {
    let isAcknowledged: Bool

    var body: some View {
        VStack {
            Spacer(minLength: 24)

            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
                .padding(.bottom, 24)

            Text("Privacy")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            VStack(spacing: 8) {
                Text(
                    "We collect your email, device name and model, OS version, and IP address. This enables us to connect your device to your network securely."
                )
                Text(
                    "Your traffic is end-to-end encrypted and is never readable by us or anyone outside your network."
                )
                Text(
                    "Your traffic is routed securely through our network infrastructure."
                )
            }
            .font(.body)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

            Spacer()

            // Legal links will be added when available
            Spacer().frame(minHeight: 16)
        }
    }
}

// MARK: - System Extension Page (content only)

private struct MacOnboardingSystemExtensionPageContent: View {
    let isCompleted: Bool
    let isInstalling: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text("Install System Extension")
                .font(.title2.weight(.semibold))
                .padding(.bottom, 2)

            Text("In System Settings: General → Login Items & Extensions → By Category → Network Extensions. Ensure CNDF-VPN.app is toggled on.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Image("InstallNetworkExtension")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.vertical, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 8)
    }
}

// MARK: - Completion Page (no accounts — prompt to log in)

private struct MacOnboardingCompletionPageContent: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 24)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundColor(.green)
                .padding(.bottom, 8)

            Text("You're All Set")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("Setup is complete. You can now log in to connect to your network.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Image("PangolinMenuBarIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 44)
                Text("Look for the CNDF-VPN icon in your menu bar to log in.")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .padding(.horizontal, 24)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 8)
    }
}

// MARK: - Window configuration (matches LoginView title bar style)

private struct OnboardingWindowAccessor: NSViewRepresentable {
    var callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let window = view.window { callback(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = nsView.window { callback(window) }
        }
    }
}

// MARK: - VPN Page (content only)

private struct MacOnboardingVPNPageContent: View {
    let vpnInstalled: Bool
    let isInstalling: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text("Add VPN Configuration")
                .font(.title2.weight(.semibold))
                .padding(.bottom, 2)

            Text("When prompted, tap \"Allow\" so CNDF-VPN can add a VPN configuration. Your traffic will be routed securely to your private network.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Image("AllowVPN")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.vertical, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 8)
    }
}
