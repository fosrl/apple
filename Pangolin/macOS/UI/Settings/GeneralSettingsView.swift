import SwiftUI
import AppKit

/// App-wide settings for this Mac. Unlike `ConnectionSettingsView`, these are the same for
/// every organization and account.
struct GeneralSettingsView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager()
    @State private var showLaunchAtLoginErrorAlert = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Form {
                    Section(header: Text("Startup")) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Start at Login")
                                    .font(.system(size: 13))
                                Text("Automatically open Pangolin when you log in to your Mac.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { launchAtLoginManager.isEnabled },
                                set: { newValue in
                                    launchAtLoginManager.setEnabled(newValue)
                                    if launchAtLoginManager.errorMessage != nil {
                                        showLaunchAtLoginErrorAlert = true
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                    }

                    OnDemandActivationSection(
                        configManager: configManager,
                        tunnelManager: tunnelManager
                    )
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Start at Login", isPresented: $showLaunchAtLoginErrorAlert) {
            Button("OK", role: .cancel) {
                launchAtLoginManager.errorMessage = nil
            }
        } message: {
            Text(launchAtLoginManager.errorMessage ?? "Unable to update the Start at Login setting.")
        }
        .onAppear {
            launchAtLoginManager.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLoginManager.refresh()
        }
    }
}
