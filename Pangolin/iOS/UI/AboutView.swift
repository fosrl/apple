//
//  AboutView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

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
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    
                    Link(destination: URL(string: "https://docs.pangolin.net/about/how-pangolin-works")!) {
                        HStack {
                            Text("How Pangolin Works")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Documentation")
                }
                
                Section {
                    Link(destination: URL(string: "https://pangolin.net/terms-of-service.html")!) {
                        HStack {
                            Text("Terms of Service")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    
                    Link(destination: URL(string: "https://pangolin.net/privacy-policy.html")!) {
                        HStack {
                            Text("Privacy Policy")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Legal")
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
