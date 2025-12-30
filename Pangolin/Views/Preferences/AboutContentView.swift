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
        ScrollView {
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 40)
                
                // App icon and name
                VStack(spacing: 12) {
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 128, height: 128)
                            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
                    }
                    
                    Text(appName)
                        .font(.system(size: 28, weight: .light))
                    
                    Text("Version \(appVersion) (\(buildNumber))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 40)
                
                // Copyright
                Text(copyright)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 30)
                
                // Links section
                VStack(spacing: 8) {
                    Link("Documentation", destination: URL(string: "https://docs.pangolin.net/")!)
                        .font(.system(size: 13))
                    
                    Link("How Pangolin Works", destination: URL(string: "https://docs.pangolin.net/about/how-pangolin-works")!)
                        .font(.system(size: 13))
                    
                    Divider()
                        .padding(.vertical, 8)
                    
                    Link("Terms of Service", destination: URL(string: "https://pangolin.net/terms-of-service.html")!)
                        .font(.system(size: 13))
                    
                    Link("Privacy Policy", destination: URL(string: "https://pangolin.net/privacy-policy.html")!)
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

