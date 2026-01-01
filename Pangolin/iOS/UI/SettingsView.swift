//
//  SettingsView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

#if os(iOS)
import SwiftUI

struct SettingsView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager
    @ObservedObject var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                NavigationLink(destination: PreferencesView(configManager: configManager)) {
                    Label("Preferences", systemImage: "gear")
                }
                
                NavigationLink(destination: StatusView(olmStatusManager: tunnelManager.olmStatusManager)) {
                    Label("Status", systemImage: "chart.bar.doc.horizontal")
                }
                
                NavigationLink(destination: AboutView()) {
                    Label("About", systemImage: "info.circle")
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
                            Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
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

