//
//  ConfigManager.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import Foundation
import Combine
import SwiftUI
import os.log

class ConfigManager: ObservableObject {
    @Published var config: Config?
    
    private let configPath: URL
    private let defaultHostname = "https://app.pangolin.net"
    
    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return OSLog(subsystem: subsystem, category: "ConfigManager")
    }()
    
    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let pangolinDir = appSupport.appendingPathComponent("Pangolin", isDirectory: true)
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: pangolinDir, withIntermediateDirectories: true)
        
        self.configPath = pangolinDir.appendingPathComponent("pangolin.json")
        self.config = load()
    }
    
    func load() -> Config? {
        guard FileManager.default.fileExists(atPath: configPath.path),
              let data = try? Data(contentsOf: configPath) else {
            return Config()
        }
        
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(Config.self, from: data)
        } catch {
            os_log("Error loading config: %{public}@", log: logger, type: .error, error.localizedDescription)
            return Config()
        }
    }
    
    func save(_ config: Config) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configPath)
            
            DispatchQueue.main.async {
                self.config = config
            }
            
            return true
        } catch {
            os_log("Error saving config: %{public}@", log: logger, type: .error, error.localizedDescription)
            return false
        }
    }
    
    func clear() -> Bool {
        var clearedConfig = config ?? Config()
        clearedConfig.userId = nil
        clearedConfig.email = nil
        clearedConfig.orgId = nil
        clearedConfig.username = nil
        clearedConfig.name = nil
        // Keep hostname
        return save(clearedConfig)
    }
    
    func getHostname() -> String {
        return config?.hostname ?? defaultHostname
    }
}

