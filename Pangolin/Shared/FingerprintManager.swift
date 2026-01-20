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
import LocalAuthentication
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
            print("Failed to push fingerprint and posture data state: \(error)")
        }
    }

    func gatherFingerprintInfo() async -> Fingerprint {
        let deviceModel = getDeviceModel()

        let architecture = getArch()

        let serialNumber = getSerialNumber()

        #if os(macOS)
            let platformUUID = getIORegistryProperty("IOPlatformUUID") ?? ""
            
            let kernelVersion = await getKernelVersion()

            let platformFingerprint = computePlatformFingerprint(
                arch: architecture, deviceModel: deviceModel, serialNumber: serialNumber,
                platformUUID: platformUUID)

        #elseif os(iOS)
            let kernelVersion = await getKernelVersion()
            let platformFingerprint = computePlatformFingerprint(persistentUUID: serialNumber)

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
            biometricsEnabled: queryBiometricsEnabled(),
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
            return computePlatformFingerprint(persistentUUID: serialNumber)
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
            return UIDevice.current.name
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
        #elseif os(iOS)
            return getOrCreatePersistentUUID()
        #else
            return ""
        #endif
    }

    private func queryAutoUpdatesEnabled() async -> Bool {
        #if os(macOS)
            let output = (await runCommand(["softwareupdate", "--schedule"])).lowercased()
            return output.contains("on")
        #else
            return false
        #endif
    }

    private func queryBiometricsEnabled() -> Bool {
        let context = LAContext()
        var error: NSError?

        return context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
    }

    private func queryDiskEncrypted() async -> Bool {
        #if os(macOS)
            let output = (await runCommand(["fdesetup", "status"])).lowercased()
            return output.contains("filevault is on")
        #else
            return false
        #endif
    }

    private func queryFirewallEnabled() async -> Bool {
        #if os(macOS)
            let output = (await runCommand([
                "/usr/bin/defaults", "read", "/Library/Preferences/com.apple.alf",
                "globalstate",
            ])).lowercased()
            // 0 = off, 1 = on for specific services, 2 = on for essential services
            return output != "0"
        #else
            return false
        #endif
    }

    private func querySipEnabled() async -> Bool {
        #if os(macOS)
            let output = (await runCommand(["csrutil", "status"])).lowercased()
            return output.contains("enabled")
        #else
            return false
        #endif
    }

    private func queryGatekeeperEnabled() async -> Bool {
        #if os(macOS)
            let output = (await runCommand(["spctl", "--status"])).lowercased()
            return output.contains("enabled")
        #else
            return false
        #endif
    }

    private func queryFirewallStealthMode() async -> Bool {
        #if os(macOS)
            let output = (await runCommand([
                "/usr/bin/defaults", "read", "com.apple.alf", "stealthenabled",
            ])).lowercased()
            return output.contains("1")
        #else
            return false
        #endif
    }

    #if os(macOS)
        private func runCommand(_ args: [String]) async -> String {
            // Run the blocking command in a background task to avoid blocking the UI
            return await Task.detached(priority: .userInitiated) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                task.arguments = args

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

            if let existing = KeychainHelper.shared.get(key: key) {
                return existing
            }

            let uuid = UUID().uuidString
            KeychainHelper.shared.set(key: key, value: uuid)
            return uuid
        }

        func computePlatformFingerprint(persistentUUID: String) -> String {
            let raw = ["ios", persistentUUID].joined(separator: "|")
            let digest = SHA256.hash(data: Data(raw.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    #endif
}
