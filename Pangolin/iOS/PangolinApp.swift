//
//  PangolinApp.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI
import os.log

#if os(iOS)
@main
struct PangolinApp: App {
    @StateObject private var configManager = ConfigManager()
    @StateObject private var secretManager = SecretManager()
    @StateObject private var accountManager = AccountManager()
    @StateObject private var apiClient: APIClient
    @StateObject private var authManager: AuthManager
    @StateObject private var tunnelManager: TunnelManager

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

        _configManager = StateObject(wrappedValue: configMgr)
        _secretManager = StateObject(wrappedValue: secretMgr)
        _accountManager = StateObject(wrappedValue: accountMgr)
        _apiClient = StateObject(wrappedValue: client)
        _authManager = StateObject(wrappedValue: authMgr)
        _tunnelManager = StateObject(wrappedValue: tunnelMgr)
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
            .onAppear {
                Task {
                    await authManager.initialize()
                }
            }
        }
    }
}
#endif

