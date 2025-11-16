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
    @State private var errorMessage: String?
    
    @ObservedObject var authManager: AuthManager
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var apiClient: APIClient
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Logo at top center
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
            
            Text("Login to Pangolin")
                .font(.title2)
                .fontWeight(.bold)
            
            if hostingOption == nil {
                // Step 1: Select hosting option
                hostingSelectionView
            } else if authManager.deviceAuthCode != nil {
                // Step 3: Show code (after starting auth)
                deviceAuthCodeView
            } else {
                // Step 2: Ready to login (hosting selected)
                readyToLoginView
            }
            
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
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
                    Button("Login") {
                        performLogin()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoggingIn || !isReadyToLogin)
                }
            }
        }
        .padding()
        .frame(width: 450, height: 400)
        .onAppear {
            // Check if hostname is already configured
            let currentHostname = configManager.getHostname()
            if currentHostname == "https://app.pangolin.net" {
                // Already set to cloud
                hostingOption = .cloud
            } else if !currentHostname.isEmpty && currentHostname != "https://app.pangolin.net" {
                // Self-hosted URL is configured
                hostingOption = .selfHosted
                selfHostedURL = currentHostname
            }
        }
    }
    
    private var hostingSelectionView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select your hosting option:")
                .font(.headline)
            
            Button(action: {
                hostingOption = .cloud
                // Set cloud hostname
                var config = configManager.config ?? Config()
                config.hostname = "https://app.pangolin.net"
                _ = configManager.save(config)
                apiClient.updateBaseURL("https://app.pangolin.net")
            }) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pangolin Cloud")
                            .font(.headline)
                        Text("app.pangolin.net")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            
            Button(action: {
                hostingOption = .selfHosted
            }) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Self-hosted or dedicated instance")
                            .font(.headline)
                        Text("Enter your custom hostname")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }
    
    private var readyToLoginView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hostingOption == .selfHosted {
                Text("Server URL")
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
            
            Divider()
            
            Text("Device Web Auth")
                .font(.headline)
            
            Text("Click Login to start the device authentication flow. A code will be displayed for you to enter on the login page.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var deviceAuthCodeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter this code on the login page:")
                .font(.headline)
            
            // Code display
            HStack {
                if let deviceCode = authManager.deviceAuthCode {
                    Text(deviceCode)
                        .font(.system(.title2, design: .monospaced))
                        .fontWeight(.bold)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)
                    
                    Button(action: {
                        copyToClipboard(deviceCode)
                    }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy code to clipboard")
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
            
            Text("Waiting for verification...")
                .font(.caption)
                .foregroundColor(.secondary)
                .italic()
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
    
    private func performLogin() {
        isLoggingIn = true
        errorMessage = nil
        
        // Ensure server URL is configured
        if hostingOption == .selfHosted {
            let url = selfHostedURL.trimmingCharacters(in: .whitespaces)
            if url.isEmpty {
                errorMessage = "Please enter a server URL."
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
                
                // Success - close window
                await MainActor.run {
                    closeWindow()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
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
