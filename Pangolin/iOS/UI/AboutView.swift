import SwiftUI

struct AboutView: View {
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
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("\(appVersion) (\(buildNumber))")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Copyright")
                        Spacer()
                        Text(copyright)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Application")
                }
                
                Section {
                    Link(destination: URL(string: "https://docs.pangolin.net/")!) {
                        HStack {
                            Text("Documentation")
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    
                    Link(destination: URL(string: "https://docs.pangolin.net/about/how-pangolin-works")!) {
                        HStack {
                            Text("How CNDF-VPN Works")
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Documentation")
                }
                
                // Legal section removed for CNDF-VPN rebrand
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
