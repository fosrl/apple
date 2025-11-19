//
//  DeviceInfo.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import Foundation
import Darwin

enum DeviceInfo {
    static func getDeviceModelName() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelString = String(cString: model)
        
        // Map model identifier to human-readable name
        return mapModelIdentifierToName(modelString)
    }
    
    private static func mapModelIdentifierToName(_ identifier: String) -> String {
        // Map model identifier prefix to device type
        if identifier.hasPrefix("MacBookPro") {
            return "MacBook Pro"
        } else if identifier.hasPrefix("MacBookAir") {
            return "MacBook Air"
        } else if identifier.hasPrefix("iMac") {
            return "iMac"
        } else if identifier.hasPrefix("Macmini") {
            return "Mac mini"
        } else if identifier.hasPrefix("MacPro") {
            return "Mac Pro"
        } else if identifier.hasPrefix("Mac13,") {
            // Mac Studio (Mac13,1 and Mac13,2)
            return "Mac Studio"
        } else if identifier.hasPrefix("Mac") {
            return "Mac"
        }
        
        // Fallback to identifier if no match
        return identifier
    }
}

