import AppKit
import SwiftUI

#if os(macOS)
/// Confirms the Pangolin CLI install, then shows its progress and result in
/// the same window, like the Windows and Linux apps.
struct CLIInstallWindow: View {
    static let windowID = "install-cli"
    static let windowTitle = "Install Pangolin CLI"

    @ObservedObject var installer: CLIInstaller
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                content
                    .padding(.top, 8)

                HStack(spacing: 8) {
                    Spacer()
                    buttons
                }
                .padding(.top, 20)
            }
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear(perform: handleDisappear)
    }

    private var title: String {
        switch installer.phase {
        case .confirm: return "Install the Pangolin CLI?"
        case .installing: return "Installing Pangolin CLI…"
        case .done: return "Pangolin CLI installed"
        case .error: return "The CLI couldn’t be installed"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch installer.phase {
        case .confirm:
            message(
                Text("This downloads and installs the latest Pangolin CLI. The CLI lets you manage your connection with the ")
                    + Text("pangolin").font(.system(.body, design: .monospaced))
                    + Text(" command in a terminal."))
        case .installing:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Downloading the CLI, then installing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .done:
            message(
                Text("The CLI was installed to \(CLIInstaller.installDirectory). Open a new terminal to use the ")
                    + Text("pangolin").font(.system(.body, design: .monospaced))
                    + Text(" command."))
        case .error(let error):
            message(Text(error.isEmpty ? "An unknown error occurred." : error))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch installer.phase {
        case .confirm:
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Install") { installer.install() }
                .keyboardShortcut(.defaultAction)
        case .installing:
            Button("Hide") { dismiss() }
                .keyboardShortcut(.cancelAction)
        case .done:
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        case .error:
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Try Again") { installer.install() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func message(_ text: Text) -> some View {
        text
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Hides the app from the Dock again once no other app window is open.
    private func handleDisappear() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let hasOtherWindows = NSApp.windows.contains { window in
                guard window.isVisible || window.isMiniaturized else { return false }
                let id = window.identifier?.rawValue ?? ""
                return id.hasPrefix("settings") || id.hasPrefix("onboarding")
                    || window.title == "Pangolin Setup"
                    || SettingsSection.allCases.contains { $0.rawValue == window.title }
            }
            guard !hasOtherWindows, NSApp.activationPolicy() != .accessory else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
#endif
