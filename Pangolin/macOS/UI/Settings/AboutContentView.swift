import SwiftUI
import AppKit

struct AboutContentView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }
    
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }
    
    private var copyright: String {
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) Fossorial, Inc."
    }
    
    var body: some View {
        // A stack so Logs opens in place, with a back button.
        NavigationStack {
            content
                .navigationDestination(for: AboutDestination.self) { _ in
                    LogsContentView()
                }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                Form {
                    Section {
                        HStack {
                            Text("Version")
                                .font(.system(size: 13))
                            Spacer()
                            Text("\(appVersion) (\(buildNumber))")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text("Copyright")
                                .font(.system(size: 13))
                            Spacer()
                            Text(copyright)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    } header: {
                        Text("Application")
                    }
                    
                    Section {
                        Link(destination: URL(string: "https://docs.pangolin.net/")!) {
                            HStack {
                                Text("Documentation")
                                    .font(.system(size: 13))
                                Spacer()
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .foregroundColor(.accentColor)
                        
                        Link(destination: URL(string: "https://docs.pangolin.net/about/how-pangolin-works")!) {
                            HStack {
                                Text("How Pangolin Works")
                                    .font(.system(size: 13))
                                Spacer()
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .foregroundColor(.accentColor)
                    } header: {
                        Text("Resources")
                    }
                    
                    Section {
                        Link(destination: URL(string: "https://pangolin.net/tos")!) {
                            HStack {
                                Text("Terms of Service")
                                    .font(.system(size: 13))
                                Spacer()
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .foregroundColor(.accentColor)
                        
                        Link(destination: URL(string: "https://pangolin.net/privacy")!) {
                            HStack {
                                Text("Privacy Policy")
                                    .font(.system(size: 13))
                                Spacer()
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .foregroundColor(.accentColor)
                    } header: {
                        Text("Legal")
                    }

                    Section {
                        NavigationLink(value: AboutDestination.logs) {
                            Text("Logs")
                                .font(.system(size: 13))
                        }
                    } header: {
                        Text("Troubleshooting")
                    } footer: {
                        Text("Messages from the app and the tunnel. Save them when reporting a problem.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


private enum AboutDestination: Hashable {
    case logs
}
