import AppKit
import SwiftUI

/// Lists the accounts on this Mac and adds, switches, and removes them.
/// Removing works with the server offline: everything local happens at once.
struct AccountsContentView: View {
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var authManager: AuthManager
    @ObservedObject var tunnelManager: TunnelManager

    /// Presents the login sheet. Presenting by item, not a flag plus a separate
    /// hostname, guarantees the sheet sees the hostname it was opened for.
    @State private var loginRequest: AccountLoginRequest?
    @State private var accountPendingRemoval: Account?
    @State private var busyAccountId: String?

    /// Sorted so the list doesn't reshuffle.
    private var accounts: [Account] {
        accountManager.accounts.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Account changes restart the tunnel, so hold them while it's starting.
    private var isTunnelStarting: Bool {
        tunnelManager.status == .starting || tunnelManager.status == .registering
    }

    var body: some View {
        Group {
            if accounts.isEmpty {
                welcomeScreen
            } else {
                accountList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            // The welcome screen has its own button.
            if !accounts.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showLogin(hostname: nil)
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .help("Add Account")
                }
            }
        }
        .sheet(item: $loginRequest) { request in
            AddAccountSheet(
                authManager: authManager,
                accountManager: accountManager,
                initialHostname: request.hostname)
        }
        .alert(
            "Remove \(accountPendingRemoval?.displayName ?? "Account")?",
            isPresented: removalAlertPresented,
            presenting: accountPendingRemoval
        ) { account in
            Button("Remove", role: .destructive) {
                remove(account)
            }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text(
                "You'll be logged out of \(Self.host(of: account)) on this Mac. You can add the account again at any time."
            )
        }
        .onReceive(PreferencesNavigation.shared.$requestedLogin) { request in
            guard let request else { return }
            PreferencesNavigation.shared.requestedLogin = nil
            loginRequest = request
        }
    }

    // MARK: - Rows

    private var accountList: some View {
        ScrollView {
            Form {
                Section {
                    ForEach(accounts) { account in
                        accountRow(account)
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    HStack {
                        Spacer()
                        Button("Add Account…") {
                            showLogin(hostname: nil)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    /// Shown until the first login, in place of the list.
    private var welcomeScreen: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text("Log In to Pangolin")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 16)

            Text("Connect to your organization's private resources by logging in to Pangolin Cloud or your own Pangolin server.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.top, 6)

            Button {
                showLogin(hostname: nil)
            } label: {
                Text("Log In…")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 24)

            Spacer()
            Spacer()
        }
        .padding(32)
    }

    private func accountRow(_ account: Account) -> some View {
        let isActive = accountManager.activeAccount?.userId == account.userId
        // Needs to log in again: its session expired, or it has none saved.
        let isLocked = (isActive && authManager.sessionExpired)
            || !authManager.hasSession(userId: account.userId)

        return HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(for: account, isActive: isActive, isLocked: isLocked))
                    .font(.system(size: 11))
                    .foregroundColor(isLocked ? .orange : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if busyAccountId == account.userId {
                ProgressView().controlSize(.small)
            } else if isLocked {
                Button("Log In…") {
                    showLogin(hostname: account.hostname)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if isActive {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("Current account")
                    .accessibilityLabel("Current account")
            } else {
                Button("Switch") {
                    switchTo(account)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busyAccountId != nil || isTunnelStarting)
            }

            Button("Remove…") {
                accountPendingRemoval = account
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(busyAccountId != nil)
        }
        .padding(.vertical, 2)
    }

    private func subtitle(for account: Account, isActive: Bool, isLocked: Bool) -> String {
        let host = Self.host(of: account)
        if isLocked { return "\(host) · Login required" }
        if isActive, let org = authManager.currentOrg { return "\(host) · \(org.name)" }
        return host
    }

    private static func host(of account: Account) -> String {
        URL(string: account.hostname)?.host ?? account.hostname
    }

    // MARK: - Actions

    private var removalAlertPresented: Binding<Bool> {
        Binding(
            get: { accountPendingRemoval != nil },
            set: { isPresented in
                if !isPresented { accountPendingRemoval = nil }
            }
        )
    }

    private func showLogin(hostname: String?) {
        loginRequest = AccountLoginRequest(hostname: hostname)
    }

    private func switchTo(_ account: Account) {
        busyAccountId = account.userId
        Task {
            await authManager.switchAccount(userId: account.userId)
            busyAccountId = nil
        }
    }

    private func remove(_ account: Account) {
        busyAccountId = account.userId
        Task {
            await authManager.deleteAccount(userId: account.userId)
            busyAccountId = nil
        }
    }
}
