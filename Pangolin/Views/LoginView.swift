//
//  LoginView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI
import AppKit

enum HostingOption {
    case cloud
    case selfHosted
}

struct LoginView: View {
    @State private var hostingOption: HostingOption?
    @State private var selfHostedURL: String = ""
    @State private var isLoggingIn = false
    @State private var isCloudButtonHovered = false
    @State private var isSelfHostedButtonHovered = false
    @State private var showSuccess = false
    @State private var hasAutoOpenedBrowser = false
    @State private var loginTask: Task<Void, Never>?
    
    @ObservedObject var authManager: AuthManager
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var apiClient: APIClient
    
    var body: some View {
        ZStack {
            // Middle content - centered in entire window
            VStack(alignment: .center, spacing: 20) {
                if showSuccess {
                    // Success view
                    successView
                } else if hostingOption == nil {
                    // Step 1: Select hosting option
                    hostingSelectionView
                } else if authManager.deviceAuthCode != nil {
                    // Step 3: Show code (after starting auth)
                    deviceAuthCodeView
                } else if hostingOption == .selfHosted {
                    // Step 2: Ready to login (only for self-hosted)
                    readyToLoginView
                }
                
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Logo at top center (fixed position)
            VStack {
                HStack {
                    Spacer()
                    Image("PangolinLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 60)
                    Spacer()
                }
                .padding(.top, 10)
                .padding(.bottom, 10)
                Spacer()
            }
            
            // Action buttons at bottom right (fixed position)
            if !showSuccess {
                VStack {
                    Spacer()
                    
                    // Terms and Privacy Policy text (only on hosting selection page)
                    if hostingOption == nil {
                        HStack(spacing: 4) {
                            Text("By continuing, you agree to our")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Button("Terms of Service") {
                                openBrowser(url: "https://pangolin.net/terms-of-service.html")
                            }
                            .font(.caption2)
                            .buttonStyle(.plain)
                            Text("and")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Button("Privacy Policy.") {
                                openBrowser(url: "https://pangolin.net/privacy-policy.html")
                            }
                            .font(.caption2)
                            .buttonStyle(.plain)
                        }
                        .padding(.bottom, 8)
                    }
                    
                    HStack {
                        Spacer()
                        
                        if hostingOption != nil {
                            Button("Back") {
                                if authManager.deviceAuthCode != nil {
                                    // Cancel the auth flow
                                    authManager.deviceAuthCode = nil
                                    authManager.deviceAuthLoginURL = nil
                                } else {
                                    hostingOption = nil
                                    selfHostedURL = ""
                                }
                            }
                            .disabled(isLoggingIn)
                        }
                        
                        Button("Cancel") {
                            closeWindow()
                        }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isLoggingIn)
                        
                        if hostingOption != nil && authManager.deviceAuthCode == nil {
                            Button("Log in") {
                                performLogin()
                            }
                            .keyboardShortcut(.defaultAction)
                            .disabled(isLoggingIn || !isReadyToLogin)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 450, height: 400)
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
    
    private var hostingSelectionView: some View {
        VStack(alignment: .center, spacing: 16) {
            Button(action: {
                hostingOption = .cloud
                // Immediately start device auth flow for cloud
                performLogin()
            }) {
                HStack {
                    VStack(alignment: .center, spacing: 4) {
                        Text("Pangolin Cloud")
                            .font(.headline)
                        Text("app.pangolin.net")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isCloudButtonHovered ? Color.accentColor : Color.clear, lineWidth: 2)
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isCloudButtonHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            
            Button(action: {
                hostingOption = .selfHosted
                // Prefill with saved hostname if it exists and is not cloud
                let savedHostname = configManager.getHostname()
                if !savedHostname.isEmpty && savedHostname != "https://app.pangolin.net" {
                    selfHostedURL = savedHostname
                }
            }) {
                HStack {
                    VStack(alignment: .center, spacing: 4) {
                        Text("Self-hosted or dedicated instance")
                            .font(.headline)
                        Text("Enter your custom hostname")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelfHostedButtonHovered ? Color.accentColor : Color.clear, lineWidth: 2)
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isSelfHostedButtonHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }
    
    private var readyToLoginView: some View {
        VStack(alignment: .center, spacing: 12) {
            if hostingOption == .selfHosted {
                Text("Pangolin Server URL")
                    .font(.headline)
                
                TextField("https://your-server.com", text: $selfHostedURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                
                Text("Enter your Pangolin server URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Pangolin Cloud")
                    .font(.headline)
                
                Text("app.pangolin.net")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
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
    
    private var deviceAuthCodeView: some View {
        VStack(alignment: .center, spacing: 12) {
            // Code display - PIN style with each digit in a box
            if let deviceCode = authManager.deviceAuthCode {
                HStack(spacing: 6) {
                    ForEach(Array(deviceCode), id: \.self) { digit in
                        Text(String(digit))
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .frame(width: 40, height: 50)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                    }
                }
            }
            
            // Buttons
            HStack(spacing: 8) {
                if let deviceCode = authManager.deviceAuthCode {
                    Button("Copy Code") {
                        copyToClipboard(deviceCode)
                    }
                    
                    if let loginURL = authManager.deviceAuthLoginURL {
                        Button("Open Browser") {
                            openBrowser(url: loginURL)
                        }
                    }
                }
            }
            
            // Manual URL instructions
            let currentHostname = getCurrentHostname()
            if !currentHostname.isEmpty {
                Text("\(currentHostname)/auth/login/device")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            ProgressView()
                .scaleEffect(0.8)
        }
        .padding(.top, 30)
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
        return configManager.getHostname()
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
                AlertManager.shared.showAlertDialog(title: "Error", message: "Please enter a server URL.")
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
                
                // Success - show success view, then close after 2 seconds
                await MainActor.run {
                    showSuccess = true
                    isLoggingIn = false
                    
                    // Close window after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        closeWindow()
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    private func openBrowser(url: String) {
        if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
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
    }
    
    private func closeWindow() {
        // Reset login state before closing
        resetLoginState()
        
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.close()
            
            // Hide app from dock when window closes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let hasOtherWindows = NSApplication.shared.windows.contains { w in
                    w.isVisible && (w.identifier?.rawValue == "main" || w.title == "Pangolin")
                }
                if !hasOtherWindows {
                    guard NSApp.activationPolicy() != .accessory else { return }
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}
