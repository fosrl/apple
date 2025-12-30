//
//  OLMStatusManager.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import Foundation
import Combine
import os.log

/// Separate ObservableObject for OLM status updates
/// This prevents menu bar re-renders when socketStatus updates
class OLMStatusManager: ObservableObject {
    @Published var socketStatus: SocketStatusResponse? = nil
    
    private let socketManager: SocketManager
    private var olmStatusPollingTask: Task<Void, Never>?
    private var isPollingOlmStatus = false
    private let socketPollInterval: TimeInterval = 2.0 // Poll every 2 seconds
    
    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return OSLog(subsystem: subsystem, category: "OLMStatusManager")
    }()
    
    init(socketManager: SocketManager) {
        self.socketManager = socketManager
    }
    
    /// Starts polling socketStatus for OLMStatusContentView live updates
    func startPolling() {
        // Stop any existing polling
        stopPolling()
        
        guard !isPollingOlmStatus else { return }
        
        isPollingOlmStatus = true
        
        olmStatusPollingTask = Task { [weak self] in
            guard let self = self else { return }
            
            while !Task.isCancelled && self.isPollingOlmStatus {
                do {
                    // Query socket for status
                    let socketStatus = try await self.socketManager.getStatus()
                    
                    // Always update socketStatus with latest data for OLMStatusContentView
                    // This provides live updates every 2 seconds
                    await MainActor.run {
                        self.socketStatus = socketStatus
                    }
                } catch {
                    // Socket not available - clear status
                    await MainActor.run {
                        self.socketStatus = nil
                    }
                }
                
                // Wait before next poll
                try? await Task.sleep(nanoseconds: UInt64(self.socketPollInterval * 1_000_000_000))
            }
        }
    }
    
    /// Stops polling socketStatus
    func stopPolling() {
        isPollingOlmStatus = false
        olmStatusPollingTask?.cancel()
        olmStatusPollingTask = nil
    }
}

