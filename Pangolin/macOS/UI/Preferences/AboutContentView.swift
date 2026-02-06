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
                        Link(destination: URL(string: "https://pangolin.net/terms-of-service.html")!) {
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
                        
                        Link(destination: URL(string: "https://pangolin.net/privacy-policy.html")!) {
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
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

