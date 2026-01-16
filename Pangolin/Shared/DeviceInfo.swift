//
//  DeviceInfo.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import Foundation
import Darwin
import os.log

#if os(macOS)
import SystemConfiguration
#endif

#if os(iOS)
import UIKit
#endif

enum DeviceInfo {
    private static let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return OSLog(subsystem: subsystem, category: "DeviceInfo")
    }()
    
    static func getDeviceModelName() -> String {
        var size = 0
        #if os(iOS)
        // On iOS, use hw.machine to get identifiers like "iPhone10,2"
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        #else
        // On macOS, use hw.model to get identifiers like "MacBookPro18,3"
        sysctlbyname("hw.model", nil, &size, nil, 0)
        #endif
        
        var model = [CChar](repeating: 0, count: size)
        #if os(iOS)
        sysctlbyname("hw.machine", &model, &size, nil, 0)
        #else
        sysctlbyname("hw.model", &model, &size, nil, 0)
        #endif
        let modelString = String(cString: model)
        
        // Map model identifier to human-readable name
        let friendlyName = mapModelIdentifierToName(modelString)
        
        os_log("Device model - raw: %{public}@, mapped: %{public}@", log: logger, type: .info, modelString, friendlyName)
        
        return friendlyName
    }
    
    
    private static func mapModelIdentifierToName(_ identifier: String) -> String {
         if identifier.contains("Mac") {
             return "Mac"
         } else if identifier.contains("iPhone") {
             return "iPhone"
         } else if identifier.contains("iPad") {
             return "iPad"
         }
        
        return identifier
    }
}

