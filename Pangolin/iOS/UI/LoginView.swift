//
//  LoginView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI
import UIKit
import AuthenticationServices

enum HostingOption {
    case cloud
    case selfHosted
}

struct LoginView: View {
    @State private var hostingOption: HostingOption?
    @State private var selfHostedURL: String = ""
    @State private var isLoggingIn = false
    @State private var showSuccess = false
    @State private var hasAutoOpenedBrowser = false
    @State private var loginTask: Task<Void, Never>?
    @State private var webAuthSession: ASWebAuthenticationSession?
    @State private var presentationContextProvider: WebAuthPresentationContextProvider?
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var authManager: AuthManager
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var apiClient: APIClient

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    // Logo
                    Image("PangolinLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 60)
                        .padding(.top, 20)

                    if showSuccess {
                        // Success view
                        successView
                    } else if hostingOption == nil {
                        // Step 1: Select hosting option
                        hostingSelectionView
                    } else if authManager.deviceAuthCode != nil {
                        // Step 3: Show code (after starting auth)
                        deviceAuthCodeView
                    } else if isLoggingIn && authManager.deviceAuthCode == nil {
                        // Step 2.5: Show loading spinner while generating device code
                        deviceCodeLoadingView
                    } else if hostingOption == .selfHosted {
                        // Step 2: Ready to login (only for self-hosted)
                        readyToLoginView
                    }
                }
                .padding()
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if hostingOption != nil && !showSuccess {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Back") {
                            // If login is in progress, cancel it
                            if isLoggingIn {
                                resetLoginState()
                            } else if authManager.deviceAuthCode != nil {
                                // Cancel the auth flow
                                authManager.deviceAuthCode = nil
                                authManager.deviceAuthLoginURL = nil
                            } else {
                                hostingOption = nil
                                selfHostedURL = ""
                            }
                        }
                    }
                }
            }
            .onChange(of: authManager.deviceAuthCode) { oldValue, newValue in
                // Auto-open browser when code is generated
                if let code = newValue, !hasAutoOpenedBrowser {
                    hasAutoOpenedBrowser = true
                    // Use temporary hostname from login flow
                    let hostname = getCurrentHostname()
                    if !hostname.isEmpty {
                        // Remove middle hyphen from code (e.g., "XXXX-XXXX" -> "XXXXXXXX")
                        let codeWithoutHyphen = code.replacingOccurrences(of: "-", with: "")
                        let autoOpenURL = "\(hostname)/auth/login/device?code=\(codeWithoutHyphen)"
                        openBrowser(url: autoOpenURL)
                    }
                } else if newValue == nil {
                    // Reset flag when code is cleared
                    hasAutoOpenedBrowser = false
                }
            }
            .onChange(of: hostingOption) { oldValue, newValue in
                // Reset auto-open flag when hosting option changes
                if newValue == nil {
                    hasAutoOpenedBrowser = false
                }
            }
            .onDisappear {
                // Reset state when view disappears
                resetLoginState()
            }
        }
    }

    private var hostingSelectionView: some View {
        VStack(spacing: 16) {
            Button(action: {
                hostingOption = .cloud
                // Immediately start device auth flow for cloud
                performLogin()
            }) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pangolin Cloud")
                            .font(.headline)
                        Text("app.pangolin.net")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding()
                .background(Color(.systemGray5))
                .cornerRadius(24)
            }
            .buttonStyle(.plain)

            Button(action: {
                hostingOption = .selfHosted
                // Prefill with saved hostname if it exists and is not cloud
                let savedHostname = accountManager.activeAccount?.hostname ?? ""

                if !savedHostname.isEmpty && savedHostname != "https://app.pangolin.net" {
                    selfHostedURL = savedHostname
                }
            }) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Self-hosted or dedicated instance")
                            .font(.headline)
                        Text("Enter your custom hostname")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding()
                .background(Color(.systemGray5))
                .cornerRadius(24)
            }
            .buttonStyle(.plain)

            // Terms and Privacy Policy
            HStack(spacing: 4) {
                Text("By continuing, you agree to our")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Terms of Service") {
                    openBrowser(url: "https://pangolin.net/terms-of-service.html")
                }
                .font(.caption)
                .buttonStyle(.plain)
                Text("and")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Privacy Policy.") {
                    openBrowser(url: "https://pangolin.net/privacy-policy.html")
                }
                .font(.caption)
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
    }

    private var readyToLoginView: some View {
        VStack(spacing: 20) {
            if hostingOption == .selfHosted {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Server URL", text: $selfHostedURL)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemGray5))
                        .cornerRadius(24)
                }
            } else {
                VStack(spacing: 8) {
                    Text("Pangolin Cloud")
                        .font(.headline)
                    Text("app.pangolin.net")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }

            Button(action: performLogin) {
                HStack {
                    if isLoggingIn {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    Text(isLoggingIn ? "Logging in..." : "Continue")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isLoggingIn || !isReadyToLogin)
        }
    }

    private var successView: some View {
        VStack(alignment: .center, spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            Text("Authentication Successful")
                .font(.title2)
                .fontWeight(.bold)

            Text("You have been successfully logged in.")
                .font(.body)
                .foregroundColor(.secondary)
        }
    }

    private var deviceCodeLoadingView: some View {
        VStack(spacing: 24) {
            Text("Generating login code...")
                .font(.headline)
                .multilineTextAlignment(.center)
            
            ProgressView()
                .scaleEffect(1.2)
                .padding(.top, 8)
        }
    }

    private var deviceAuthCodeView: some View {
        VStack(spacing: 24) {
            Text("Enter this code on the login page")
                .font(.headline)
                .multilineTextAlignment(.center)

            // Code display - compact PIN style that fits on all screen sizes
            // For 8 characters: ~32pt width each + 4pt spacing = ~284pt total, fits on all iPhones
            if let deviceCode = authManager.deviceAuthCode {
                HStack(spacing: 4) {
                    ForEach(Array(deviceCode.enumerated()), id: \.offset) { index, digit in
                        Text(String(digit))
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .frame(width: 32, height: 44)
                            .background(index == 4 ? Color.clear : Color(.systemGray5))
                            .cornerRadius(index == 4 ? 0 : 8)
                    }
                }
            }

            // Buttons
            VStack(spacing: 12) {
                if let deviceCode = authManager.deviceAuthCode {
                    Button(action: {
                        copyToClipboard(deviceCode)
                    }) {
                        Text("Copy Code")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    if let loginURL = authManager.deviceAuthLoginURL {
                        Button(action: {
                            openExternalBrowser(url: loginURL)
                        }) {
                            Text("Open Login Page")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
            }

            // Manual URL instructions
            let currentHostname = getCurrentHostname()
            if !currentHostname.isEmpty {
                Text("Or visit: \(currentHostname)/auth/login/device")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            ProgressView()
                .padding(.top, 8)
        }
    }

    private var isReadyToLogin: Bool {
        if hostingOption == .cloud {
            return true
        } else if hostingOption == .selfHosted {
            return !selfHostedURL.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return false
    }

    private func getCurrentHostname() -> String {
        if hostingOption == .cloud {
            return "https://app.pangolin.net"
        } else if hostingOption == .selfHosted {
            let url = selfHostedURL.trimmingCharacters(in: .whitespaces)
            if !url.isEmpty {
                // Normalize the URL
                var normalized = url
                if !normalized.hasPrefix("http://") && !normalized.hasPrefix("https://") {
                    normalized = "https://" + normalized
                }
                normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return normalized
            }
        }

        return accountManager.activeAccount?.hostname ?? ConfigManager.defaultHostname
    }

    private func performLogin() {
        isLoggingIn = true

        // Determine hostname to use for login
        let hostname: String?
        if hostingOption == .cloud {
            hostname = "https://app.pangolin.net"
        } else if hostingOption == .selfHosted {
            let url = selfHostedURL.trimmingCharacters(in: .whitespaces)
            if url.isEmpty {
                AlertManager.shared.showAlertDialog(
                    title: "Error", message: "Please enter a server URL.")
                isLoggingIn = false
                return
            }
            // Normalize the URL
            var normalized = url
            if !normalized.hasPrefix("http://") && !normalized.hasPrefix("https://") {
                normalized = "https://" + normalized
            }
            normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            hostname = normalized
        } else {
            hostname = nil
        }

        loginTask = Task {
            do {
                try await authManager.loginWithDeviceAuth(hostnameOverride: hostname)

                // Success - show success view, then dismiss after 2 seconds
                await MainActor.run {
                    showSuccess = true
                    isLoggingIn = false
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        // Reset state after showing success
                        resetLoginState()
                        // Dismiss the sheet if presented as one
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    // Don't show error if task was cancelled
                    if !Task.isCancelled {
                        AlertManager.shared.showErrorDialog(error)
                    }
                    isLoggingIn = false
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    private func openBrowser(url: String) {
        guard let url = URL(string: url) else {
            return
        }
        
        // Use ASWebAuthenticationSession for secure in-app browser
        // This uses Safari's secure browser and complies with Google's policies
        let provider = WebAuthPresentationContextProvider()
        presentationContextProvider = provider
        
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "pangolin"
        ) { callbackURL, error in
            // Handle callback if needed (for OAuth flows)
            // For device auth, we just need to show the page, not handle redirects
            if let error = error {
                // User cancelled or error occurred
                let nsError = error as NSError
                if nsError.domain == ASWebAuthenticationSessionErrorDomain && nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    // User cancelled - this is expected, don't log as error
                    print("User cancelled web auth session")
                } else {
                    print("Web auth session error: \(error.localizedDescription)")
                }
            }
        }
        
        // Set presentation context and start session
        session.presentationContextProvider = provider
        session.prefersEphemeralWebBrowserSession = false
        
        // Start on main thread
        DispatchQueue.main.async {
            let started = session.start()
            if !started {
                print("Failed to start ASWebAuthenticationSession")
                // Fallback to external browser
                UIApplication.shared.open(url)
            } else {
                webAuthSession = session
            }
        }
    }
    
    private func openExternalBrowser(url: String) {
        // Always open in external browser (Safari)
        if let url = URL(string: url) {
            UIApplication.shared.open(url)
        }
    }

    private func resetLoginState() {
        // Cancel login task if it exists
        loginTask?.cancel()
        loginTask = nil

        // Cancel device auth polling
        authManager.cancelDeviceAuth()

        // Reset local state
        isLoggingIn = false
        hostingOption = nil
        selfHostedURL = ""
        showSuccess = false
        hasAutoOpenedBrowser = false
        webAuthSession?.cancel()
        webAuthSession = nil
        presentationContextProvider = nil
    }
}

// Presentation context provider for ASWebAuthenticationSession
class WebAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Get the key window from all connected scenes
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                // Try to get the key window first
                if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                    return keyWindow
                }
                // Fallback to first window
                if let window = windowScene.windows.first {
                    return window
                }
            }
        }
        
        // Last resort: try to get any window
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            return window
        }
        
        // This should never happen in normal usage
        fatalError("No window available for ASWebAuthenticationSession")
    }
}
