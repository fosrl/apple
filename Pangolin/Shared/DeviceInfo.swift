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
        #if os(macOS)
        // On macOS, try to get friendly name from system_profiler first
        if let machineName = getMacOSMachineName() {
            os_log("Device model from system_profiler: %{public}@", log: logger, type: .info, machineName)
            return machineName
        }
        
        // Fall back to sysctl method
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelString = String(cString: model)
        
        let friendlyName = mapModelIdentifierToName(modelString)
        os_log("Device model - raw: %{public}@, mapped: %{public}@", log: logger, type: .info, modelString, friendlyName)
        return friendlyName
        #elseif os(iOS)
        // On iOS, use hw.machine to get identifiers like "iPhone10,2"
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &model, &size, nil, 0)
        let modelString = String(cString: model)
        
        let friendlyName = mapModelIdentifierToName(modelString)
        os_log("Device model - raw: %{public}@, mapped: %{public}@", log: logger, type: .info, modelString, friendlyName)
        return friendlyName
        #endif
    }
    
    #if os(macOS)
    private static func getMacOSMachineName() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPHardwareDataType", "-json"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            
            struct SPHardwareOutput: Codable {
                let machineName: String?
                
                enum CodingKeys: String, CodingKey {
                    case machineName = "machine_name"
                }
            }
            
            struct SystemProfilerOutput: Codable {
                let hardwareData: [SPHardwareOutput]?
                
                enum CodingKeys: String, CodingKey {
                    case hardwareData = "SPHardwareDataType"
                }
            }
            
            let decoder = JSONDecoder()
            let output = try decoder.decode(SystemProfilerOutput.self, from: data)
            
            if let firstHardware = output.hardwareData?.first,
               let machineName = firstHardware.machineName,
               !machineName.isEmpty {
                return machineName
            }
        } catch {
            os_log("Failed to get machine name from system_profiler: %{public}@", log: logger, type: .error, error.localizedDescription)
        }
        
        return nil
    }
    #endif
    
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

