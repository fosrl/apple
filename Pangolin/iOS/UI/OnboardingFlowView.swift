import SwiftUI
import Combine

/// View-model that coordinates which onboarding pages to show and when to dismiss.
@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var isPresenting: Bool = false
    @Published var isInstallingVPN: Bool = false
    @Published var currentIndex: Int = 0

    @Published private(set) var hasSeenWelcome: Bool
    @Published private(set) var hasAcknowledgedPrivacy: Bool
    @Published private(set) var vpnInstalled: Bool = false

    private let onboardingState: OnboardingStateManager
    private let tunnelManager: TunnelManager

    init(onboardingState: OnboardingStateManager, tunnelManager: TunnelManager) {
        self.onboardingState = onboardingState
        self.tunnelManager = tunnelManager
        self.hasSeenWelcome = onboardingState.hasSeenWelcome
        self.hasAcknowledgedPrivacy = onboardingState.hasAcknowledgedPrivacy
    }

    /// Re-computes which pages should be visible based on local state and VPN configuration.
    func refreshPages() async {
        hasSeenWelcome = onboardingState.hasSeenWelcome
        hasAcknowledgedPrivacy = onboardingState.hasAcknowledgedPrivacy
        vpnInstalled = await tunnelManager.isVPNProfileInstalled()

        // Show onboarding whenever any step is incomplete.
        let needsWelcome = !hasSeenWelcome
        let needsPrivacy = !hasAcknowledgedPrivacy
        let needsVPN = !vpnInstalled

        isPresenting = needsWelcome || needsPrivacy || needsVPN

        // When presenting, start at the first incomplete step and skip completed ones.
        if isPresenting {
            if needsWelcome {
                currentIndex = 0
            } else if needsPrivacy {
                currentIndex = 1
            } else {
                currentIndex = 2
            }
        }
    }

    func handleWelcomeContinue() {
        onboardingState.markWelcomeSeen()
        hasSeenWelcome = true
        goToNextPage()
    }

    func handlePrivacyAcknowledge() {
        onboardingState.markPrivacyAcknowledged()
        hasAcknowledgedPrivacy = true
        goToNextPage()
    }

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

    func handleDoneTapped() {
        isPresenting = false
    }

    private func goToNextPage() {
        currentIndex = min(currentIndex + 1, 2)
    }
}

struct OnboardingFlowView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            TabView(selection: $viewModel.currentIndex) {
                OnboardingWelcomePage(
                    isCompleted: viewModel.hasSeenWelcome,
                    onContinue: {
                        withAnimation {
                            viewModel.handleWelcomeContinue()
                        }
                    }
                )
                .tag(0)
                .padding(.horizontal, 24)

                OnboardingPrivacyPage(
                    isAcknowledged: viewModel.hasAcknowledgedPrivacy,
                    onAcknowledge: {
                        withAnimation {
                            viewModel.handlePrivacyAcknowledge()
                        }
                    }
                )
                .tag(1)
                .padding(.horizontal, 24)

                OnboardingInstallVPNPage(
                    vpnInstalled: viewModel.vpnInstalled,
                    hasAcknowledgedPrivacy: viewModel.hasAcknowledgedPrivacy,
                    isInstalling: viewModel.isInstallingVPN,
                    installAction: {
                        Task {
                            await viewModel.handleVPNInstallTapped()
                        }
                    },
                    doneAction: {
                        withAnimation {
                            viewModel.handleDoneTapped()
                        }
                    }
                )
                .tag(2)
                .padding(.horizontal, 24)
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
            .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
        }
    }
}

// MARK: - Individual Pages

private struct OnboardingWelcomePage: View {
    let isCompleted: Bool
    let onContinue: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 40)

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

            if isCompleted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("You’ve already seen this introduction.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 8)
            }

            Button(action: onContinue) {
                Text("Next")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)

            // Footer help text (kept above the page indicator)
            if let docsURL = URL(string: "https://docs.pangolin.net/about/how-pangolin-works") {
                HStack(spacing: 4) {
                    Text("New to CNDF-VPN?")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Link("Learn more.", destination: docsURL)
                        .font(.caption)
                }
                .padding(.top, 12)
                // Extra bottom padding so dots don't overlap the help text
                .padding(.bottom, 56)
            } else {
                Spacer().frame(height: 56)
            }
        }
    }
}

private struct OnboardingPrivacyPage: View {
    let isAcknowledged: Bool
    let onAcknowledge: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 40)

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
                    "If you're using a self-hosted CNDF-VPN server, all data remains on your server and is never sent to our servers."
                )
            }
            .font(.body)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

            Spacer()

            if isAcknowledged {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("You’ve already confirmed the privacy policy.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 8)
            }

            Button(action: onAcknowledge) {
                Text(isAcknowledged ? "Next" : "I understand")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)

            // Terms/privacy footer removed for CNDF-VPN rebrand
            Spacer().frame(height: 56)
        }
    }
}

private struct OnboardingInstallVPNPage: View {
    let vpnInstalled: Bool
    let hasAcknowledgedPrivacy: Bool
    let isInstalling: Bool
    let installAction: () -> Void
    let doneAction: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 40)

            Image(systemName: "network")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
                .padding(.bottom, 24)

            Text("Add VPN Configuration")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            Text(
                "CNDF-VPN needs to add a VPN configuration so it can securely route traffic to devices and services on your private network."
            )
            .font(.body)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

            Spacer()

            if vpnInstalled {
                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("VPN configuration installed")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 12)

                    Button(action: doneAction) {
                        Text("Done")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                // Extra bottom padding so dots don't overlap the button
                .padding(.bottom, 56)
            } else {
                Button(action: installAction) {
                    HStack {
                        if isInstalling {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        }
                        Text(isInstalling ? "Installing…" : "Install")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isInstalling || !hasAcknowledgedPrivacy)
                    // Extra bottom padding so dots don't overlap the button
                    .padding(.bottom, 56)
            }
        }
    }
}

