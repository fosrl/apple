import AppKit
import SwiftUI

/// Logs in to a Pangolin server with device login, shown as a sheet on the
/// Accounts section. The user picks a server, approves the code in their
/// browser, and the new account becomes active.
struct AddAccountSheet: View {
    @ObservedObject var authManager: AuthManager
    let accountManager: AccountManager
    /// Server to log in to right away, e.g. to renew a locked account. When nil,
    /// the sheet asks which server to use.
    let initialHostname: String?

    @Environment(\.dismiss) private var dismiss

    private enum Server: Hashable {
        case cloud
        case selfHosted
    }

    @State private var server: Server = .cloud
    @State private var selfHostedURL = ""
    @State private var loginHostname: String?
    @State private var loginTask: Task<Void, Never>?
    @State private var isLoggingIn = false
    @State private var didSucceed = false
    @State private var errorMessage: String?
    @State private var hasOpenedBrowser = false
    @State private var didCopyCode = false

    private static let cloudHostname = ConfigManager.defaultHostname

    init(authManager: AuthManager, accountManager: AccountManager, initialHostname: String?) {
        self.authManager = authManager
        self.accountManager = accountManager
        self.initialHostname = initialHostname
        // Renewing opens on the code step, rather than flashing the server choice
        // until the login starts.
        if let initialHostname {
            _isLoggingIn = State(initialValue: true)
            _loginHostname = State(initialValue: initialHostname)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.menuBlur)
                .id(step)

            Divider()

            buttons
                .padding(16)
        }
        .frame(width: 440)
        .animation(.smooth(duration: 0.3), value: step)
        .onAppear(perform: prepare)
        .onDisappear {
            if !didSucceed { cancelLogin() }
        }
        .onChange(of: authManager.deviceAuthCode) { _, code in
            if let code { openBrowserOnce(code: code) }
        }
    }

    // MARK: - Steps

    private enum Step: Hashable {
        case server
        /// Starting a login the user picked the server for.
        case starting
        /// Starting a login to a known account, before there's a code.
        case loading
        case code(String)
        case success
    }

    private var step: Step {
        if didSucceed { return .success }
        guard isLoggingIn else { return .server }
        if let code = authManager.deviceAuthCode { return .code(code) }
        return initialHostname != nil ? .loading : .starting
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .server:
            serverStep
        case .starting:
            startingStep
        case .loading:
            // Just a spinner, like the menu while it loads. It turns into the
            // code if the login starts, or the server choice if it can't.
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 200)
        case .code(let code):
            codeStep(code: code)
        case .success:
            successStep
        }
    }

    private var serverStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(
                title: "Add Account",
                subtitle: "Log in to Pangolin Cloud or to your own Pangolin server.")

            Picker("Server", selection: $server) {
                serverOption(title: "Pangolin Cloud", detail: "app.pangolin.net")
                    .tag(Server.cloud)
                serverOption(title: "Self-hosted or dedicated", detail: "Your organization's Pangolin server")
                    .tag(Server.selfHosted)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if server == .selfHosted {
                TextField(
                    "Server URL", text: $selfHostedURL,
                    // Verbatim, or the URL is styled as a link.
                    prompt: Text(verbatim: "https://pangolin.example.com")
                )
                .textFieldStyle(.roundedBorder)
                .padding(.leading, 20)
            }

            if let errorMessage {
                errorLabel(errorMessage)
            }

            legalNotice
        }
    }

    private var startingStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(title: "Add Account", subtitle: "Contacting \(displayHost(loginHostname))…")
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 12)
        }
    }

    private func codeStep(code: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(
                title: initialHostname == nil ? "Approve in Your Browser" : "Log In Again",
                subtitle:
                    "Your browser opened \(displayHost(loginHostname)). Check that it shows this code, then approve the login."
            )

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ForEach(Array(code.enumerated()), id: \.offset) { _, character in
                    codeCharacter(character)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Code \(code)")

            HStack(spacing: 8) {
                Spacer()
                Button(didCopyCode ? "Copied" : "Copy Code") {
                    copyCode(code)
                }
                Button("Open Browser") {
                    reopenBrowser()
                }
                Spacer()
            }

            HStack(spacing: 6) {
                Spacer()
                ProgressView().controlSize(.small)
                Text("Waiting for approval…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var successStep: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("You're Logged In")
                .font(.headline)
            if let name = authManager.currentUser?.email ?? accountManager.activeAccount?.displayName {
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 12) {
            if isLoggingIn && initialHostname == nil && !didSucceed {
                Button("Back") {
                    cancelLogin()
                }
            }

            Spacer()

            if didSucceed {
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            } else {
                Button("Cancel") {
                    cancelLogin()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if !isLoggingIn {
                    Button("Continue") {
                        continueLogin()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(server == .selfHosted && normalizedSelfHostedURL == nil)
                }
            }
        }
        .controlSize(.large)
    }

    // MARK: - Pieces

    private func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func serverOption(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 13))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func codeCharacter(_ character: Character) -> some View {
        Text(String(character))
            .font(.system(size: 22, weight: .semibold, design: .monospaced))
            .frame(width: character == "-" ? 14 : 34, height: 44)
            .background {
                if character != "-" {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor))
                        )
                }
            }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var legalNotice: some View {
        HStack(spacing: 4) {
            Text("By continuing, you agree to the")
            Link(destination: URL(string: "https://pangolin.net/tos")!) {
                Text("Terms of Service").underline()
            }
            Text("and")
            Link(destination: URL(string: "https://pangolin.net/privacy")!) {
                Text("Privacy Policy").underline()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    // MARK: - Login

    private func prepare() {
        if let initialHostname {
            // Renewing a known account: skip the server choice.
            if initialHostname == Self.cloudHostname {
                server = .cloud
            } else {
                server = .selfHosted
                selfHostedURL = initialHostname
            }
            startLogin(hostname: initialHostname)
            return
        }

        // Offer the active self-hosted server, handy for adding a second user.
        if let hostname = accountManager.activeAccount?.hostname, hostname != Self.cloudHostname {
            selfHostedURL = hostname
        }
    }

    /// The self-hosted URL with a scheme and without trailing slashes, or nil if empty.
    private var normalizedSelfHostedURL: String? {
        var url = selfHostedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "https://" + url
        }
        return url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func continueLogin() {
        switch server {
        case .cloud:
            startLogin(hostname: Self.cloudHostname)
        case .selfHosted:
            guard let hostname = normalizedSelfHostedURL else { return }
            startLogin(hostname: hostname)
        }
    }

    private func startLogin(hostname: String) {
        if loginTask != nil { cancelLogin() }
        errorMessage = nil
        loginHostname = hostname
        hasOpenedBrowser = false
        isLoggingIn = true

        loginTask = Task {
            do {
                try await authManager.loginWithDeviceAuth(hostnameOverride: hostname)
                didSucceed = true
                isLoggingIn = false
                try? await Task.sleep(for: .seconds(1))
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                isLoggingIn = false
                errorMessage = Self.message(for: error)
            }
        }
    }

    /// Stops a login in progress, including the server polling.
    private func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        if isLoggingIn {
            authManager.cancelDeviceAuth()
        }
        isLoggingIn = false
    }

    private func openBrowserOnce(code: String) {
        guard !hasOpenedBrowser, let hostname = loginHostname else { return }
        hasOpenedBrowser = true

        var url = "\(hostname)/auth/login/device?code=\(code.replacingOccurrences(of: "-", with: ""))"
        // When renewing an account, prefill its user on the login page.
        if initialHostname != nil, let email = accountManager.activeAccount?.email, !email.isEmpty {
            url += "&user=\(email.addingFormURLEncoding)"
        }
        open(url)
    }

    private func reopenBrowser() {
        if let url = authManager.deviceAuthLoginURL {
            open(url)
        } else if let hostname = loginHostname {
            open("\(hostname)/auth/login/device")
        }
    }

    private func copyCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        didCopyCode = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopyCode = false
        }
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func displayHost(_ hostname: String?) -> String {
        guard let hostname else { return "the server" }
        return URL(string: hostname)?.host ?? hostname
    }

    private static func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.errorDescription ?? error.localizedDescription
        }
        return error.localizedDescription
    }
}
