//
//  OLMStatusContentView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI
import AppKit

struct OLMStatusContentView: View {
    @ObservedObject var olmStatusManager: OLMStatusManager
    
    // Computed property to format socket status as JSON
    private var statusJSON: String? {
        guard let socketStatus = olmStatusManager.socketStatus else {
            return nil
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let jsonData = try? encoder.encode(socketStatus),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return jsonString
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let json = statusJSON {
                    Text(json)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                } else {
                    Text("Unable to get status via socket. Is the tunnel extension running?")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Start separate polling for live updates when view appears
            olmStatusManager.startPolling()
        }
        .onDisappear {
            // Stop polling when view disappears to avoid unnecessary work
            olmStatusManager.stopPolling()
        }
    }
}

