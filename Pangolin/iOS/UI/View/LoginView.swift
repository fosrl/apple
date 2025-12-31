//
//  LoginView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

#if os(iOS)
import SwiftUI

enum HostingOption {
    case cloud
    case selfHosted
}

struct LoginView: View {
    @State private var hostingOption: HostingOption?
    @State private var selfHostedURL: String = ""
    @State private var isLoggingIn = false
    @State private var showSuccess = false
    @State private var loginTask: Task<Void, Never>?

    @ObservedObject var authManager: AuthManager
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var apiClient: APIClient
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                // Logo
                Image("PangolinLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 80)
                    .padding(.top, 40)
                
                if showSuccess {
                    successView
                } else if hostingOption == nil {
                    hostingSelectionView
                } else if authManager.deviceAuthCode != nil {
                    deviceAuthCodeView
                } else if hostingOption == .selfHosted {
                    readyToLoginView
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Pangolin")
        }
    }
    
    private var hostingSelectionView: some View {
        VStack(spacing: 20) {
            Text("Choose your hosting option")
                .font(.headline)
                .padding(.bottom, 10)
            
            Button(action: {
                hostingOption = .cloud
            }) {
                HStack {
                    Image(systemName: "cloud.fill")
                    Text("Cloud Hosted")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            
            Button(action: {
                hostingOption = .selfHosted
            }) {
                HStack {
                    Image(systemName: "server.rack")
                    Text("Self Hosted")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.gray)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
        }
        .padding()
    }
    
    private var readyToLoginView: some View {
        VStack(spacing: 20) {
            Text("Enter your server URL")
                .font(.headline)
            
            TextField("https://your-server.com", text: $selfHostedURL)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            
            Button(action: performLogin) {
                if isLoggingIn {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    Text("Continue")
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(isLoggingIn ? Color.gray : Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
            .disabled(isLoggingIn)
            
            Button(action: {
                hostingOption = nil
            }) {
                Text("Back")
            }
        }
        .padding()
    }
    
    private var deviceAuthCodeView: some View {
        VStack(spacing: 20) {
            Text("Enter this code on the login page")
                .font(.headline)
            
            if let code = authManager.deviceAuthCode {
                Text(code)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
                
                if let url = authManager.deviceAuthLoginURL {
                    Link("Open Login Page", destination: URL(string: url)!)
                        .buttonStyle(.borderedProminent)
                }
            }
            
            Button(action: {
                authManager.deviceAuthCode = nil
                authManager.deviceAuthLoginURL = nil
            }) {
                Text("Cancel")
            }
        }
        .padding()
    }
    
    private var successView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
            
            Text("Login Successful!")
                .font(.headline)
        }
        .padding()
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

                // Success - show success view
                await MainActor.run {
                    showSuccess = true
                    isLoggingIn = false
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
}
#endif

