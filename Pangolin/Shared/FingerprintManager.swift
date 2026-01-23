//
//  SocketManager.swift
//  Pangolin
//
//  Created by Varun Narravula on 1/6/2025.
//

import Combine
import CryptoKit
import Darwin
import Foundation
import os.log

#if os(macOS)
    import IOKit
#endif

#if os(iOS)
    import UIKit
#endif

class FingerprintManager {
    // Set to false to entirely disable interval fingerprint checks
    private let intervalFingerprintCheckEnabled: Bool = true

    private let socketManager: SocketManager
    private var task: Task<Void, Never>?

    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return OSLog(subsystem: subsystem, category: "FingerprintManager")
    }()

    init(socketManager: SocketManager) {
        self.socketManager = socketManager
    }

    func start(interval: TimeInterval = 30) {
        guard task == nil else { return }
        guard intervalFingerprintCheckEnabled else { return }

        #if os(iOS)
            // Don't run background metadata updates on iOS
            return
        #endif

        task = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if await self.socketManager.isRunning() {
                    await self.runUpdateMetadata()
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func runUpdateMetadata() async {
        guard intervalFingerprintCheckEnabled else { return }

        guard await socketManager.isRunning() else { return }

        let fingerprint = await gatherFingerprintInfo()
        let postures = await gatherPostureChecks()

        do {
            _ = try await socketManager.updateMetadata(fingerprint: fingerprint, postures: postures)
        } catch {
            os_log("Failed to push fingerprint and posture data state: %{public}@", log: logger, type: .error, error.localizedDescription)
        }
    }

    func gatherFingerprintInfo() async -> Fingerprint {
        let deviceModel = getDeviceModel()

        let kernelVersion = await getKernelVersion()

        let architecture = getArch()

        let serialNumber = getSerialNumber()

        #if os(macOS)
            let platformUUID = getIORegistryProperty("IOPlatformUUID") ?? ""

            let platformFingerprint = computePlatformFingerprint(
                arch: architecture, deviceModel: deviceModel, serialNumber: serialNumber,
                platformUUID: platformUUID)

        #elseif os(iOS)
            let pseudoSerialNumber = getOrCreatePersistentUUID()

            let platformFingerprint = computePlatformFingerprint(persistentUUID: pseudoSerialNumber)
        #endif

        return Fingerprint(
            username: getUsername(),
            hostname: getHostname(),
            platform: getPlatformString(),
            osVersion: getOSVersion(),
            kernelVersion: kernelVersion,
            arch: architecture,
            deviceModel: deviceModel,
            serialNumber: serialNumber,
            platformFingerprint: platformFingerprint,
        )
    }

    func gatherPostureChecks() async -> Postures {
        return Postures(
            autoUpdatesEnabled: await queryAutoUpdatesEnabled(),
            biometricsEnabled: await queryBiometricsEnabled(),
            diskEncrypted: await queryDiskEncrypted(),
            firewallEnabled: await queryFirewallEnabled(),
            // Secure Enclave and T2 are always available on iOS and macOS.
            tpmAvailable: true,

            macosSipEnabled: await querySipEnabled(),
            macosGatekeeperEnabled: await queryGatekeeperEnabled(),
            macosFirewallStealthMode: await queryFirewallStealthMode(),
        )
    }

    func getPlatformFingerprintHash() -> String {
        let serialNumber = getSerialNumber()

        #if os(macOS)
            let platformUUID = getIORegistryProperty("IOPlatformUUID") ?? ""
            let architecture = getArch()
            let deviceModel = getDeviceModel()

            return computePlatformFingerprint(
                arch: architecture, deviceModel: deviceModel, serialNumber: serialNumber,
                platformUUID: platformUUID)
        #elseif os(iOS)
            return computePlatformFingerprint(persistentUUID: getOrCreatePersistentUUID())
        #else
            return ""
        #endif
    }

    private func getUsername() -> String {
        #if os(macOS)
            return NSUserName()
        #else
            return ""
        #endif
    }

    private func getHostname() -> String {
        #if os(macOS)
            return Host.current().localizedName ?? ""
        #elseif os(iOS)
            return ""
        #else
            return ""
        #endif
    }

    private func getPlatformString() -> String {
        #if os(macOS)
            return "macos"
        #elseif os(iOS)
            return "ios"
        #else
            return ""
        #endif
    }

    private func getOSVersion() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    private func getKernelVersion() async -> String {
        #if os(macOS)
            return await runCommand(["uname", "-r"])
        #elseif os(iOS)
            var uts = utsname()
            uname(&uts)

            let kernelVersion = withUnsafePointer(to: &uts.release) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }

            return kernelVersion
        #else
            return ""
        #endif
    }

    private func getArch() -> String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return ""
        #endif
    }

    private func getDeviceModel() -> String {
        #if os(macOS)
            return getIORegistryProperty("model")?.trimmingCharacters(in: .controlCharacters) ?? ""
        #elseif os(iOS)
            var uts = utsname()
            uname(&uts)

            let modelIdentifier = withUnsafePointer(to: &uts.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }

            return modelIdentifier
        #else
            return ""
        #endif
    }

    private func getSerialNumber() -> String {
        #if os(macOS)
            return getIORegistryProperty("IOPlatformSerialNumber") ?? ""
        #else
            return ""
        #endif
    }

    private func queryAutoUpdatesEnabled() async -> Bool {
        #if os(macOS)
            // Check all required keys are set to 1
            let keys = ["AutomaticDownload", "AutomaticallyInstallMacOSUpdates", "ConfigDataInstall", "CriticalUpdateInstall"]
            var allEnabled = true
            
            for key in keys {
                let rawOutput = await runCommand(["defaults", "read", "/Library/Preferences/com.apple.SoftwareUpdate.plist", key])
                os_log("queryAutoUpdatesEnabled() - Key: %{public}@, Raw output: %{public}@", log: logger, type: .debug, key, rawOutput)
                
                let valueStr = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                if valueStr != "1" {
                    // If we can't read a key or it's not "1", assume not enabled
                    allEnabled = false
                    break
                }
            }
            
            return allEnabled
        #else
            return false
        #endif
    }

    private func queryBiometricsEnabled() async -> Bool {
        #if os(macOS)
            let rawOutput = await runCommand(["bioutil", "-r"])
            os_log("queryBiometricsEnabled() - Raw output: %{public}@", log: logger, type: .debug, rawOutput)
            
            // Regex pattern: "Biometrics for unlock:" followed by optional whitespace and digits
            let pattern = "Biometrics for unlock:\\s*(\\d+)"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                return false
            }
            
            let range = NSRange(rawOutput.startIndex..<rawOutput.endIndex, in: rawOutput)
            guard let match = regex.firstMatch(in: rawOutput, options: [], range: range) else {
                return false
            }
            
            // matches[0] is the full match, matches[1] is the captured group (the number)
            if match.numberOfRanges > 1 {
                let numberRange = match.range(at: 1)
                if let swiftRange = Range(numberRange, in: rawOutput),
                   let number = Int(rawOutput[swiftRange]),
                   number > 0 {
                    return true
                }
            }
            
            return false
        #else
            return false
        #endif
    }

    private func queryDiskEncrypted() async -> Bool {
        #if os(macOS)
            let rawOutput = await runCommand(["fdesetup", "status"])
            os_log("queryDiskEncrypted() - Raw output: %{public}@", log: logger, type: .debug, rawOutput)
            let output = rawOutput.lowercased()
            return output.contains("filevault is on")
        #else
            return false
        #endif
    }

    private func queryFirewallEnabled() async -> Bool {
        #if os(macOS)
            let rawOutput = await runCommand([
                "/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate",
            ])
            os_log("queryFirewallEnabled() - Raw output: %{public}@", log: logger, type: .debug, rawOutput)
            let output = rawOutput.lowercased()
            // Output is "Firewall is enabled. (State = 1)" or "Firewall is disabled. (State = 0)"
            return output.contains("enabled")
        #else
            return false
        #endif
    }

    private func querySipEnabled() async -> Bool {
        #if os(macOS)
            let rawOutput = await runCommand(["csrutil", "status"])
            os_log("querySipEnabled() - Raw output: %{public}@", log: logger, type: .debug, rawOutput)
            let output = rawOutput.lowercased()
            return output.contains("enabled")
        #else
            return false
        #endif
    }

    private func queryGatekeeperEnabled() async -> Bool {
        #if os(macOS)
            let rawOutput = await runCommand(["spctl", "--status"])
            os_log("queryGatekeeperEnabled() - Raw output: %{public}@", log: logger, type: .debug, rawOutput)
            let output = rawOutput.lowercased()
            return output.contains("enabled")
        #else
            return false
        #endif
    }

    private func queryFirewallStealthMode() async -> Bool {
        #if os(macOS)
            let rawOutput = await runCommand([
                "/usr/libexec/ApplicationFirewall/socketfilterfw", "--getstealthmode",
            ])
            os_log("queryFirewallStealthMode() - Raw output: %{public}@", log: logger, type: .debug, rawOutput)
            let output = rawOutput.lowercased()
            // Output is "Firewall stealth mode is on" or "Firewall stealth mode is off"
            return output.contains("is on")
        #else
            return false
        #endif
    }

    #if os(macOS)
        private func runCommand(_ args: [String]) async -> String {
            // Run the blocking command in a background task to avoid blocking the UI
            return await Task.detached(priority: .userInitiated) {
                let task = Process()
                
                // If first argument is a full path, use it directly; otherwise use env
                if args.first?.hasPrefix("/") == true {
                    task.executableURL = URL(fileURLWithPath: args[0])
                    task.arguments = Array(args.dropFirst())
                } else {
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    task.arguments = args
                }

                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe

                do {
                    try task.run()
                    task.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    return String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                } catch {
                    return ""
                }
            }.value
        }

        private func getIORegistryProperty(_ key: String) -> String? {
            let service = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching("IOPlatformExpertDevice"))

            if let cfProp = IORegistryEntryCreateCFProperty(
                service,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() {

                if CFGetTypeID(cfProp) == CFDataGetTypeID(),
                    let data = cfProp as? Data,
                    let str = String(data: data, encoding: .utf8)
                {
                    return str
                }

                if let str = cfProp as? String {
                    return str
                }
            }

            return nil
        }

        func computePlatformFingerprint(
            arch: String, deviceModel: String, serialNumber: String, platformUUID: String
        ) -> String {
            let raw = [
                "macos", arch, deviceModel.lowercased(), serialNumber.lowercased(),
                platformUUID.lowercased(),
            ]
            .joined(separator: "|")
            let digest = SHA256.hash(data: Data(raw.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    #endif

    #if os(iOS)
        private func getOrCreatePersistentUUID() -> String {
            let key = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
            os_log("getOrCreatePersistentUUID() - Key: %{public}@", log: logger, type: .debug, key)

            if let existing = KeychainHelper.shared.get(key: key) {
                os_log("getOrCreatePersistentUUID() - Found existing UUID in Keychain: %{public}@", log: logger, type: .debug, existing)
                return existing
            }

            let uuid = UUID().uuidString
            os_log("getOrCreatePersistentUUID() - No existing UUID found, creating new UUID: %{public}@", log: logger, type: .debug, uuid)
            KeychainHelper.shared.set(key: key, value: uuid)
            os_log("getOrCreatePersistentUUID() - Stored new UUID in Keychain with key: %{public}@", log: logger, type: .debug, key)
            return uuid
        }

        func computePlatformFingerprint(persistentUUID: String) -> String {
            os_log("computePlatformFingerprint() - Input persistentUUID: %{public}@", log: logger, type: .debug, persistentUUID)
            let raw = ["ios", persistentUUID].joined(separator: "|")
            os_log("computePlatformFingerprint() - Raw string to hash: %{public}@", log: logger, type: .debug, raw)
            let digest = SHA256.hash(data: Data(raw.utf8))
            let result = digest.map { String(format: "%02x", $0) }.joined()
            os_log("computePlatformFingerprint() - Resulting fingerprint hash: %{public}@", log: logger, type: .debug, result)
            return result
        }
    #endif
}
