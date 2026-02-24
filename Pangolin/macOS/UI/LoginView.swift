import AppKit
import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a: UInt64
        let r: UInt64
        let g: UInt64
        let b: UInt64
        switch hex.count {
        case 3:  // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

struct LoginView: View {
    @State private var isLoggingIn = false
    @State private var showSuccess = false
    @State private var hasAutoOpenedBrowser = false
    @State private var hasAutoStartedLogin = false
    @State private var loginTask: Task<Void, Never>?

    @ObservedObject var authManager: AuthManager
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var apiClient: APIClient
    @Environment(\.colorScheme) private var colorScheme

    private var windowBackgroundColor: Color {
        colorScheme == .dark ? Color(hex: "161618") : Color(hex: "FDFDFD")
    }

    var body: some View {
        ZStack {
            // Middle content - centered in entire window
            VStack(alignment: .center, spacing: 20) {
                if showSuccess {
                    // Success view
                    successView
                } else if authManager.deviceAuthCode != nil {
                    // Show code (after starting auth)
                    deviceAuthCodeView
                } else {
                    // Waiting for auth to start
                    ProgressView()
                        .scaleEffect(0.8)
                }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Logo at top center (fixed position)
            VStack {
                HStack {
                    Spacer()
                    Image("CNDFLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 60)
                    Spacer()
                }
                .padding(.bottom, 15)
                Spacer()
            }

            // Action buttons at bottom right (fixed position)
            if !showSuccess {
                VStack {
                    Spacer()

                    HStack {
                        Spacer()

                        Button("Cancel") {
                            closeWindow()
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                }
            }
        }
        .frame(width: 440, height: 300)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(windowBackgroundColor)
        .background(
            WindowAccessor { window in
                configureWindow(window)
            }
        )
        .onAppear {
            if !hasAutoStartedLogin {
                hasAutoStartedLogin = true
                authManager.startDeviceAuthImmediately = false
                performLogin()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard NSApp.activationPolicy() != .regular else { return }
                NSApp.setActivationPolicy(.regular)
                if let window = NSApplication.shared.windows.first(where: { $0.title == "CNDF-VPN" }) {
                    configureWindow(window)
                    let duplicates = NSApplication.shared.windows.filter { w in
                        (w.identifier?.rawValue == "main" || w.title == "CNDF-VPN") && w != window
                    }
                    for duplicate in duplicates {
                        duplicate.close()
                    }
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            notification in
            if let window = notification.object as? NSWindow, window.identifier?.rawValue == "main"
            {
                configureWindow(window)
            }
        }
        .onChange(of: authManager.deviceAuthCode) { oldValue, newValue in
            // Auto-open browser when code is generated
                if let code = newValue, !hasAutoOpenedBrowser {
                    hasAutoOpenedBrowser = true
                    let hostname = getCurrentHostname()
                    if !hostname.isEmpty {
                        let codeWithoutHyphen = code.replacingOccurrences(of: "-", with: "")
                        let username = accountManager.activeAccount?.email ?? authManager.currentUser?.username ?? authManager.currentUser?.email ?? ""
                        let usernameEncoded = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        let autoOpenURL = "\(hostname)/auth/login/device?code=\(codeWithoutHyphen)&user=\(usernameEncoded)"
                        openBrowser(url: autoOpenURL)
                    }
                } else if newValue == nil {
                // Reset flag when code is cleared
                hasAutoOpenedBrowser = false
            }
        }
        .onDisappear {
            // Reset state when view disappears
            resetLoginState()
            
            // Hide app from dock when window closes (if no other windows)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let hasOtherWindows = NSApplication.shared.windows.contains { window in
                    window.isVisible && (window.identifier?.rawValue == "main" || window.identifier?.rawValue == "preferences")
                }
                if !hasOtherWindows {
                    guard NSApp.activationPolicy() != .accessory else { return }
                    NSApp.setActivationPolicy(.accessory)
                }
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
                    ForEach(Array(deviceCode.enumerated()), id: \.offset) { index, digit in
                        Text(String(digit))
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .frame(width: 40, height: 50)
                            .background(digit == "-" ? Color.clear : Color.secondary.opacity(0.1))
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

    private func getCurrentHostname() -> String {
        return "https://app.pangolin.net"
    }

    private func performLogin() {
        isLoggingIn = true
        let hostname = "https://app.pangolin.net"

        loginTask = Task {
            do {
                try await authManager.loginWithDeviceAuth(hostnameOverride: hostname)

                // Success
                await MainActor.run {
                    showSuccess = true
                    isLoggingIn = false
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
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
        showSuccess = false
        hasAutoOpenedBrowser = false
        hasAutoStartedLogin = false
    }

    private func configureWindow(_ window: NSWindow) {
        // Set identifier if not set
        if window.identifier?.rawValue != "main" {
            window.identifier = NSUserInterfaceItemIdentifier("main")
        }

        // Configure window style: remove minimize and maximize, keep close button
        var styleMask = window.styleMask
        styleMask.remove([.miniaturizable, .resizable])
        styleMask.insert([.titled, .closable])
        window.styleMask = styleMask

        // Ensure resizing is disabled
        window.styleMask.remove(.resizable)

        // Hide minimize and zoom buttons, keep only close button
        if let minimizeButton = window.standardWindowButton(.miniaturizeButton) {
            minimizeButton.isHidden = true
        }
        if let zoomButton = window.standardWindowButton(.zoomButton) {
            zoomButton.isHidden = true
        }
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.isHidden = false
        }

        // Set window to not be resizable
        window.isMovableByWindowBackground = false

        // Set window size explicitly
        var frame = window.frame
        frame.size = NSSize(width: 440, height: 300)
        window.setContentSize(frame.size)
    }

    private func closeWindow() {
        // Reset login state before closing
        resetLoginState()

        if let window = NSApplication.shared.windows.first(where: {
            $0.identifier?.rawValue == "main"
        }) {
            window.close()
        }
    }
}

// Helper view to access NSWindow
struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let window = view.window {
                callback(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = nsView.window {
                callback(window)
            }
        }
    }
}
