//
//  AboutView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

#if os(iOS)
import SwiftUI

struct AboutView: View {
    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Pangolin"
    }
    
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
        ScrollView {
            VStack(spacing: 20) {
                // App icon and name header
                VStack(spacing: 12) {
                    Image("PangolinLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                    
                    Text(appName)
                        .font(.title2)
                        .fontWeight(.medium)
                }
                .padding(.top, 20)
                .padding(.bottom, 16)
                
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
                        Text("Resources")
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
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

