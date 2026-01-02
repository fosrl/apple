//
//  MainView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

#if os(iOS)
import SwiftUI

struct MainView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var authManager: AuthManager
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var tunnelManager: TunnelManager
    @State private var showAccountPicker = false
    @State private var showOrganizationPicker = false
    
    var body: some View {
        TabView {
            HomeTabView(
                configManager: configManager,
                authManager: authManager,
                accountManager: accountManager,
                tunnelManager: tunnelManager,
                showAccountPicker: $showAccountPicker,
                showOrganizationPicker: $showOrganizationPicker
            )
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }
            
            StatusView(olmStatusManager: tunnelManager.olmStatusManager)
                .tabItem {
                    Label("Status", systemImage: "chart.bar.doc.horizontal")
                }
            
            PreferencesView(configManager: configManager)
                .tabItem {
                    Label("Preferences", systemImage: "gear")
                }
            
            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .sheet(isPresented: $showAccountPicker) {
            AccountPickerView(
                accountManager: accountManager,
                authManager: authManager,
                tunnelManager: tunnelManager
            )
        }
        .sheet(isPresented: $showOrganizationPicker) {
            OrganizationPickerView(
                authManager: authManager,
                tunnelManager: tunnelManager
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
                                get: { tunnelManager.isNEConnected },
                                set: { isOn in
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
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(16)
                    
                    // User Info Card
                    if let user = authManager.currentUser {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "person.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.accentColor)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(user.email)
                                        .font(.headline)
                                    
                                    if let org = authManager.currentOrg {
                                        Text(org.name)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                Spacer()
                            }
                            
                            Divider()
                            
                            // Account switching
                            if accountManager.accounts.count > 1 {
                                Button(action: {
                                    showAccountPicker = true
                                }) {
                                    HStack {
                                        Text("Switch Account")
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.secondary)
                                            .font(.caption)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            
                            // Organization switching
                            if authManager.organizations.count > 1 {
                                Button(action: {
                                    showOrganizationPicker = true
                                }) {
                                    HStack {
                                        Text("Switch Organization")
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.secondary)
                                            .font(.caption)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(16)
                    }
                }
                .padding()
            }
        }
    }
}

// MARK: - Account Picker

struct AccountPickerView: View {
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var authManager: AuthManager
    @ObservedObject var tunnelManager: TunnelManager
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
                
                Section {
                    Button(role: .destructive, action: {
                        Task {
                            await authManager.logout()
                            dismiss()
                        }
                    }) {
                        HStack {
                            Spacer()
                            Text("Logout")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Accounts")
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
#endif

