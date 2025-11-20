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
                let hostname = configManager.getHostname()
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
    }
    
    private var hostingSelectionView: some View {
        VStack(alignment: .center, spacing: 16) {
            Button(action: {
                hostingOption = .cloud
                // Set cloud hostname
                var config = configManager.config ?? Config()
                config.hostname = "https://app.pangolin.net"
                _ = configManager.save(config)
                apiClient.updateBaseURL("https://app.pangolin.net")
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
                    .onChange(of: selfHostedURL) { oldValue, newValue in
                        // Update config and API client as user types
                        var config = configManager.config ?? Config()
                        config.hostname = newValue.isEmpty ? nil : newValue
                        _ = configManager.save(config)
                        if !newValue.isEmpty {
                            apiClient.updateBaseURL(newValue)
                        }
                    }
                
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
            if !configManager.getHostname().isEmpty {
                Text("If the browser doesn't open, manually visit \(configManager.getHostname())/auth/device-web-auth/start to complete authentication.")
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
    
    private func performLogin() {
        isLoggingIn = true
        
        // Ensure server URL is configured
        if hostingOption == .selfHosted {
            let url = selfHostedURL.trimmingCharacters(in: .whitespaces)
            if url.isEmpty {
                AlertManager.shared.showAlertDialog(title: "Error", message: "Please enter a server URL.")
                isLoggingIn = false
                return
            }
            var config = configManager.config ?? Config()
            config.hostname = url
            _ = configManager.save(config)
            apiClient.updateBaseURL(url)
        }
        
        Task {
            do {
                try await authManager.loginWithDeviceAuth()
                
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
                    AlertManager.shared.showErrorDialog(error)
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
    
    private func closeWindow() {
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
