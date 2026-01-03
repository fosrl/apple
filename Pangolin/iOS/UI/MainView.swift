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
    @State private var optimisticToggleState: Bool = false
    
    private var tunnelStatus: TunnelStatus {
        tunnelManager.status
    }
    
    private var isInIntermediateState: Bool {
        switch tunnelStatus {
        case .connecting, .registering, .reconnecting, .disconnecting:
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
        case .connecting, .registering, .reconnecting:
            return .orange
        case .disconnecting:
            return .orange
        case .error, .invalid:
            return .red
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
                    
                    // Tunnel Status Card
                    VStack(spacing: 0) {
                        VStack(spacing: 16) {
                            // Status indicator with toggle
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 12, height: 12)
                                
                                Text(tunnelStatus.displayText)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                Toggle("", isOn: Binding(
                                    get: { optimisticToggleState },
                                    set: { isOn in
                                        // Optimistically update the toggle state immediately
                                        optimisticToggleState = isOn
                                        Task {
                                            if isOn {
                                                await tunnelManager.connect()
                                            } else {
                                                await tunnelManager.disconnect()
                                            }
                                        }
                                    }
                                ))
                                .disabled(isInIntermediateState)
                                .onChange(of: tunnelManager.isNEConnected) { newValue in
                                    // Sync optimistic state with actual state when it changes
                                    optimisticToggleState = newValue
                                }
                                .onAppear {
                                    // Initialize optimistic state from actual state
                                    optimisticToggleState = tunnelManager.isNEConnected
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(24)
                        
                        // Status page dropdown button (only when connected)
                        if tunnelStatus == .connected {
                            Button(action: {
                                selectedTab = .status
                            }) {
                                HStack {
                                    Image(systemName: "app.connected.to.app.below.fill")
                                        .font(.system(size: 14))
                                    
                                    Text("View Status Details")
                                    
                                    Spacer()
                                    
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12))
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
                    if let user = authManager.currentUser {
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
                                            .font(.title)
                                            .foregroundColor(.accentColor)
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(user.email)
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
                                                .font(.title)
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
                                    Image(systemName: "rectangle.grid.3x1.fill")
                                        .font(.title)
                                        .foregroundColor(.accentColor)
                                    
                                    Text(" Visit Dashboard")
                                        .font(.headline)
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
                        
                        // Documentation button
                        if let docsURL = URL(string: "https://docs.pangolin.net") {
                            Link(destination: docsURL) {
                                HStack {
                                    Image(systemName: "book.fill")
                                        .font(.title)
                                        .foregroundColor(.accentColor)
                                    
                                    Text("Documentation")
                                        .font(.headline)
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
    
    private var accounts: [Account] {
        return Array(accountManager.accounts.values)
    }
    
    private var emailCounts: [String: Int] {
        Dictionary(grouping: accounts, by: { $0.email }).mapValues { $0.count }
    }
    
    private var currentAccountUserId: String? {
        accountManager.activeAccount?.userId
    }
    
    private func formatEmailHostname(account: Account) -> String {
        let count = emailCounts[account.email, default: 0]
        
        let text =
            count > 1
            ? "\(account.email) (\(account.hostname))"
            : account.email
        
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
                            let accountLabelText = formatEmailHostname(account: account)
                            
                            Button(action: {
                                Task {
                                    await authManager.switchAccount(userId: account.userId)
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
        }
    }
}

// MARK: - Organization Picker

struct OrganizationPickerView: View {
    @ObservedObject var authManager: AuthManager
    @ObservedObject var tunnelManager: TunnelManager
    @Environment(\.dismiss) private var dismiss
    
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
                                await authManager.selectOrganization(org)
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
        }
    }
}
