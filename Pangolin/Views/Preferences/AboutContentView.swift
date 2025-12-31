//
//  AboutContentView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI
import AppKit

struct AboutContentView: View {
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
    
    private var appIcon: NSImage? {
        NSImage(named: NSImage.applicationIconName)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // App icon and name header
                VStack(spacing: 12) {
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                    }
                    
                    Text(appName)
                        .font(.system(size: 22, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                .padding(.bottom, 16)
                
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
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Link(destination: URL(string: "https://docs.pangolin.net/about/how-pangolin-works")!) {
                            HStack {
                                Text("How Pangolin Works")
                                    .font(.system(size: 13))
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Text("Resources")
                    }
                    
                    Section {
                        Link(destination: URL(string: "https://pangolin.net/terms-of-service.html")!) {
                            HStack {
                                Text("Terms of Service")
                                    .font(.system(size: 13))
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Link(destination: URL(string: "https://pangolin.net/privacy-policy.html")!) {
                            HStack {
                                Text("Privacy Policy")
                                    .font(.system(size: 13))
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
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

