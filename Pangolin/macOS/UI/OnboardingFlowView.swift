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

    @MainActor
    init(onboardingState: OnboardingStateManager, tunnelManager: TunnelManager) {
        self.onboardingState = onboardingState
        self.tunnelManager = tunnelManager
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
        isPresenting = false
        hasOpenedOnboardingWindowThisSession = false
        closeOnboardingWindow()
    }

    @MainActor
    func goToNextPage() {
        currentIndex = min(currentIndex + 1, 3)
    }

    @MainActor
    func goToPreviousPage() {
        currentIndex = max(0, currentIndex - 1)
    }

    @MainActor
    private func closeOnboardingWindow() {
        if let window = NSApplication.shared.windows.first(where: { $0.title == "Pangolin Setup" }) {
            window.close()
        }
    }
}

struct MacOnboardingFlowView: View {
    @ObservedObject var viewModel: MacOnboardingViewModel
    @Environment(\.colorScheme) private var colorScheme

    private static let stepCount = 4

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
                    ForEach(0..<Self.stepCount, id: \.self) { index in
                        Circle()
                            .fill(index <= viewModel.currentIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                    Spacer()
                    Text("Step \(viewModel.currentIndex + 1) of \(Self.stepCount)")
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
                    default:
                        MacOnboardingVPNPageContent(
                            vpnInstalled: viewModel.vpnInstalled,
                            isInstalling: viewModel.isInstallingVPN
                        )
                    }
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Footer: confirmation text (bottom left) ↔ Back + primary action (bottom right)
                HStack(alignment: .center) {
                    footerConfirmationText
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if viewModel.currentIndex > 0 {
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
        .frame(minWidth: 440, minHeight: 400)
        .background(windowBackgroundColor)
        .background(
            OnboardingWindowAccessor { window in
                configureOnboardingWindow(window)
            }
        )
        .onAppear {
            DispatchQueue.main.async {
                NSApplication.shared.windows.first { $0.title == "Pangolin Setup" }?.makeKeyAndOrderFront(nil)
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
        default:
            return (viewModel.vpnInstalled, "VPN configuration installed")
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
                Button {
                    Task { await viewModel.handleSystemExtensionInstallTapped() }
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isInstallingSystemExtension {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.7)
                        }
                        Text(viewModel.isInstallingSystemExtension ? "Installing…" : "Install System Extension")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isInstallingSystemExtension)
            }
        default:
            if viewModel.vpnInstalled {
                Button("Done") {
                    viewModel.handleDoneTapped()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    Task { await viewModel.handleVPNInstallTapped() }
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isInstallingVPN {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.7)
                        }
                        Text(viewModel.isInstallingVPN ? "Installing…" : "Install")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isInstallingVPN)
            }
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

            Text("Welcome to Pangolin")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            Text(
                "Pangolin securely connects your devices to your private networks, so you can safely access internal apps and resources from anywhere."
            )
            .font(.body)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

            Spacer()

            if let docsURL = URL(string: "https://docs.pangolin.net/about/how-pangolin-works") {
                HStack(spacing: 4) {
                    Text("New to Pangolin?")
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
                    "If you're using a self-hosted Pangolin server, all data remains on your server and is never sent to our servers."
                )
            }
            .font(.body)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

            Spacer()

            if let termsURL = URL(string: "https://pangolin.net/terms-of-service.html"),
               let privacyURL = URL(string: "https://pangolin.net/privacy-policy.html") {
                let attributed: AttributedString = {
                    var string = AttributedString(
                        "By continuing, you agree to our Terms of Service and Privacy Policy."
                    )
                    if let range = string.range(of: "Terms of Service") {
                        string[range].link = termsURL
                    }
                    if let range = string.range(of: "Privacy Policy") {
                        string[range].link = privacyURL
                    }
                    return string
                }()

                Text(attributed)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            Spacer().frame(minHeight: 16)
        }
    }
}

// MARK: - System Extension Page (content only)

private struct MacOnboardingSystemExtensionPageContent: View {
    let isCompleted: Bool
    let isInstalling: Bool

    var body: some View {
        VStack {
            Spacer(minLength: 24)

            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
                .padding(.bottom, 24)

            Text("Install System Extension")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            Text(
                "Pangolin uses a system extension to provide secure network access. You may be prompted to allow the extension in System Settings → Privacy & Security."
            )
            .font(.body)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

            Spacer()

            if isInstalling {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Installing…")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)
            }
            Spacer().frame(minHeight: 16)
        }
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
        VStack {
            Spacer(minLength: 24)

            Image(systemName: "network")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
                .padding(.bottom, 24)

            Text("Add VPN Configuration")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            Text(
                "Pangolin needs to add a VPN configuration so it can securely route traffic to devices and services on your private network."
            )
            .font(.body)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

            Spacer()

            if isInstalling {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Installing…")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)
            }
            Spacer().frame(minHeight: 16)
        }
    }
}
