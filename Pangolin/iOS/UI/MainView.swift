//
//  MainView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI

enum TabSelection: Int {
    case home = 0
    case status = 1
    case preferences = 2
    case about = 3
}

struct MainView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var authManager: AuthManager
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var tunnelManager: TunnelManager
    @ObservedObject var apiClient: APIClient
    @State private var showAccountPicker = false
    @State private var showOrganizationPicker = false
    @State private var showLoginView = false
    @State private var selectedTab: TabSelection = .home
    
    var body: some View {
        TabView(selection: $selectedTab) {
            HomeTabView(
                configManager: configManager,
                authManager: authManager,
                accountManager: accountManager,
                tunnelManager: tunnelManager,
                showAccountPicker: $showAccountPicker,
                showOrganizationPicker: $showOrganizationPicker,
                selectedTab: $selectedTab
            )
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }
            .tag(TabSelection.home)
            
            StatusView(olmStatusManager: tunnelManager.olmStatusManager)
                .tabItem {
                    Label("Status", systemImage: "app.connected.to.app.below.fill")
                }
            .tag(TabSelection.status)
            
            PreferencesView(configManager: configManager)
                .tabItem {
                    Label("Preferences", systemImage: "gearshape.fill")
                }
            .tag(TabSelection.preferences)
            
            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
            .tag(TabSelection.about)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showAccountPicker) {
            AccountManagementView(
                accountManager: accountManager,
                authManager: authManager,
                tunnelManager: tunnelManager,
                apiClient: apiClient,
                showLoginView: $showLoginView
            )
        }
        .sheet(isPresented: $showOrganizationPicker) {
            OrganizationPickerView(
                authManager: authManager,
                tunnelManager: tunnelManager
            )
        }
        .sheet(isPresented: $showLoginView) {
            LoginView(
                authManager: authManager,
                accountManager: accountManager,
                configManager: configManager,
                apiClient: apiClient
            )
        }
    }
}

// MARK: - Home Tab View

struct HomeTabView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var authManager: AuthManager
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var tunnelManager: TunnelManager
    @Binding var showAccountPicker: Bool
    @Binding var showOrganizationPicker: Bool
    @Binding var selectedTab: TabSelection
    
    private var tunnelStatus: TunnelStatus {
        tunnelManager.status
    }
    
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { tunnelManager.isNEConnected },
            set: { newValue in
                // Only prevent interaction when starting (not when registering)
                guard tunnelStatus != .starting else { return }
                Task {
                    if newValue {
                        await tunnelManager.connect()
                    } else {
                        await tunnelManager.disconnect()
                    }
                }
            }
        )
    }
    
    private var isInIntermediateState: Bool {
        // Used for showing loading animation - include both starting and registering
        switch tunnelStatus {
        case .starting, .registering:
            return true
        default:
            return false
        }
    }
    
    private var statusColor: Color {
        switch tunnelStatus {
        case .connected:
            return .green
        case .disconnected:
            return .gray
        case .starting, .registering:
            return .orange
        }
    }
    
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Logo
                    Image("PangolinLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 60)
                        .padding(.top, 20)
                        .padding(.bottom, 15)
                    
                    // Server down message
                    if authManager.isServerDown {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("The server appears to be down.")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(24)
                    }
                    
                    // Error message (for non-server-down errors)
                    if let errorMessage = authManager.errorMessage, !authManager.isServerDown {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.red)
                            Text(errorMessage)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(24)
                    }
                    
                    // Tunnel Status Card
                    VStack(spacing: 0) {
                        Button(action: {
                            // Only prevent interaction when starting (not when registering)
                            guard tunnelStatus != .starting else { return }
                            Task {
                                if tunnelManager.isNEConnected {
                                    await tunnelManager.disconnect()
                                } else {
                                    await tunnelManager.connect()
                                }
                            }
                        }) {
                            VStack(spacing: 16) {
                                // Status indicator with toggle
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(statusColor)
                                        .frame(width: 12, height: 12)
                                    
                                    HStack(spacing: 8) {
                                        Text(tunnelStatus.displayText)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        
                                        if isInIntermediateState {
                                            ProgressView()
                                                .scaleEffect(0.8)
                                                .id("loading-progress") // Stable ID to prevent animation restart
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    Toggle("", isOn: toggleBinding)
                                        .tint(.accentColor)
                                        .allowsHitTesting(false)
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .disabled(tunnelStatus == .starting)
                        .buttonStyle(.plain)
                        .background(Color(.systemGray6))
                        .cornerRadius(24)
                        
                        // Status page dropdown button (only when connected)
                        if tunnelStatus == .connected {
                            Button(action: {
                                selectedTab = .status
                            }) {
                                HStack {
                                    Text("View Status Details")
                                    
                                    Spacer()
                                    
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Color(.systemGray6))
                                .cornerRadius(24)
                                .padding(.top, 8)
                            }
                            .buttonStyle(.plain)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.95)),
                                removal: .opacity.combined(with: .move(edge: .top))
                            ))
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: tunnelStatus == .connected)
                    
                    // Account and Organization Section
                    if authManager.isAuthenticated {
                        VStack(alignment: .leading, spacing: 16) {
                            // Account section
                            VStack(alignment: .leading, spacing: 12) {
                                // Account section header
                                Text("Account")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                
                                // Account button
                                Button(action: {
                                    showAccountPicker = true
                                }) {
                                    HStack {
                                        Image(systemName: "person.circle.fill")
                                            .foregroundColor(.accentColor)
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            if let user = authManager.currentUser {
                                                Text(user.displayName)
                                                    .font(.headline)
                                            } else if let account = accountManager.activeAccount {
                                                Text(account.displayName)
                                                    .font(.headline)
                                            } else {
                                                Text("Account")
                                                    .font(.headline)
                                            }
                                        }
                                        
                                        Spacer()
                                        
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.secondary)
                                            .font(.caption)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            
                            // Organization section
                            if let org = authManager.currentOrg {
                                VStack(alignment: .leading, spacing: 12) {
                                    // Organization section header
                                    Text("Organization")
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                    
                                    // Organization button
                                    Button(action: {
                                        showOrganizationPicker = true
                                    }) {
                                        HStack {
                                            Image(systemName: "building.2.fill")
                                                .foregroundColor(.accentColor)
                                            
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(org.name)
                                                    .font(.headline)
                                            }
                                            
                                            Spacer()
                                            
                                            Image(systemName: "chevron.right")
                                                .foregroundColor(.secondary)
                                                .font(.caption)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            
                            // Personal license notice
                            if let serverInfo = authManager.serverInfo,
                               serverInfo.build == "enterprise",
                               let licenseType = serverInfo.enterpriseLicenseType,
                               licenseType.lowercased() == "personal" {
                                Text("Licensed for personal use only.")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                            }
                            
                            // Unlicensed enterprise notice
                            if let serverInfo = authManager.serverInfo,
                               serverInfo.build == "enterprise",
                               !serverInfo.enterpriseLicenseValid {
                                Text("This server is unlicensed.")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                            }
                            
                            // OSS community edition notice
                            if let serverInfo = authManager.serverInfo,
                               serverInfo.build == "oss",
                               !serverInfo.supporterStatusValid {
                                Text("Community Edition. Consider supporting.")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(24)
                    }
                    
                    // Links Section
                    VStack(alignment: .leading, spacing: 12) {
                        // Links section header
                        Text("Links")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        
                        // Visit Dashboard button
                        if let hostname = accountManager.activeAccount?.hostname,
                           let dashboardURL = URL(string: hostname) {
                            Link(destination: dashboardURL) {
                                HStack {
                                    Text("Visit Dashboard")
                                        .foregroundColor(.primary)
                                    
                                    Spacer()
                                    
                                    Image(systemName: "arrow.up.forward")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        
                        if let docsURL = URL(string: "https://docs.pangolin.net/about/how-pangolin-works") {
                            Link(destination: docsURL) {
                                HStack {
                                    Text("How Pangolin Works")
                                        .foregroundColor(.primary)
                                    
                                    Spacer()
                                    
                                    Image(systemName: "arrow.up.forward")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        
                        if let docsURL = URL(string: "https://docs.pangolin.net") {
                            Link(destination: docsURL) {
                                HStack {
                                    Text("Documentation")
                                        .foregroundColor(.primary)
                                    
                                    Spacer()
                                    
                                    Image(systemName: "arrow.up.forward")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(24)
                }
                .padding()
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Loading Overlay

struct LoadingOverlay: View {
    let isLoading: Bool
    let successMessage: String?
    
    var body: some View {
        if isLoading || successMessage != nil {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                
                VStack(spacing: 12) {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(1.2)
                    } else if let message = successMessage {
                        Image(systemName: "checkmark")
                            .font(.system(size: 24))
                        
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                }
                .padding(18)
                .background {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color(.systemBackground))
                }
            }
        }
    }
}

// MARK: - Account Management

struct AccountManagementView: View {
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var authManager: AuthManager
    @ObservedObject var tunnelManager: TunnelManager
    @ObservedObject var apiClient: APIClient
    @Binding var showLoginView: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var isSwitchingAccount = false
    @State private var isDeletingAccount = false
    @State private var showSuccessMessage: String? = nil
    
    private var accounts: [Account] {
        return Array(accountManager.accounts.values)
    }
    
    private var emailCounts: [String: Int] {
        Dictionary(grouping: accounts, by: { $0.email }).mapValues { $0.count }
    }
    
    private var currentAccountUserId: String? {
        accountManager.activeAccount?.userId
    }
    
    private func formatAccountLabel(account: Account) -> String {
        let displayName = account.displayName
        let count = emailCounts[account.email, default: 0]
        
        // If multiple accounts share the same email, show hostname to differentiate
        let text =
            count > 1
            ? "\(displayName) (\(account.hostname))"
            : displayName
        
        return text
    }
    
    private var shouldDisableAccountButton: Bool {
        switch tunnelManager.status {
        case .connecting, .registering, .reconnecting, .disconnecting:
            return true
        default:
            return false
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                if !accounts.isEmpty {
                    Section {
                        ForEach(accounts, id: \.userId) { account in
                            let accountLabelText = formatAccountLabel(account: account)
                            
                            Button(action: {
                                Task {
                                    isSwitchingAccount = true
                                    await authManager.switchAccount(userId: account.userId)
                                    isSwitchingAccount = false
                                    showSuccessMessage = "Switched Account"
                                    
                                    // Wait a moment to show success message, then dismiss
                                    try? await Task.sleep(nanoseconds: 250_000_000)
                                    dismiss()
                                }
                            }) {
                                HStack {
                                    Text(accountLabelText)
                                        .foregroundColor(.primary)
                                    
                                    Spacer()
                                    
                                    if currentAccountUserId == account.userId {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                            .disabled(shouldDisableAccountButton || currentAccountUserId == account.userId)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task {
                                        isDeletingAccount = true
                                        await authManager.deleteAccount(userId: account.userId)
                                        isDeletingAccount = false
                                        
                                        // If we deleted the active account and there are no more accounts, dismiss
                                        if accountManager.activeAccount == nil {
                                            dismiss()
                                        }
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("Available Accounts")
                    }
                }
                
                Section {
                    Button(action: {
                        dismiss()
                        showLoginView = true
                    }) {
                        HStack {
                            Text("Add Account")
                        }
                    }
                    
                    if accountManager.activeAccount != nil {
                        Button(role: .destructive, action: {
                            Task {
                                await authManager.logout()
                                dismiss()
                            }
                        }) {
                            HStack {
                                Text("Logout")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .overlay {
                LoadingOverlay(isLoading: isSwitchingAccount || isDeletingAccount, successMessage: showSuccessMessage)
            }
        }
    }
}

// MARK: - Organization Picker

struct OrganizationPickerView: View {
    @ObservedObject var authManager: AuthManager
    @ObservedObject var tunnelManager: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @State private var isSwitchingOrg = false
    @State private var showSuccessMessage: String? = nil
    
    private var organizations: [Organization] {
        authManager.organizations
    }
    
    private var currentOrgId: String? {
        authManager.currentOrg?.orgId
    }
    
    private var shouldDisableOrgButtons: Bool {
        switch tunnelManager.status {
        case .connecting, .registering, .reconnecting, .disconnecting:
            return true
        default:
            return false
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(organizations, id: \.orgId) { org in
                        Button(action: {
                            Task {
                                isSwitchingOrg = true
                                await authManager.selectOrganization(org)
                                isSwitchingOrg = false
                                showSuccessMessage = "Switched Organization"
                                
                                // Wait a moment to show success message, then dismiss
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                dismiss()
                            }
                        }) {
                            HStack {
                                Text(org.name)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                if currentOrgId == org.orgId {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .disabled(shouldDisableOrgButtons || currentOrgId == org.orgId)
                    }
                } header: {
                    Text(organizations.count == 1 ? "1 Organization" : "\(organizations.count) Organizations")
                }
            }
            .navigationTitle("Organizations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .overlay {
                LoadingOverlay(isLoading: isSwitchingOrg, successMessage: showSuccessMessage)
            }
        }
    }
}
