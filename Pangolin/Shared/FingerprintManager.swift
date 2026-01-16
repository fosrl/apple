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

class FingerprintManager: ObservableObject {
    private let socketManager: SocketManager
    private var task: Task<Void, Never>?

    init(socketManager: SocketManager) {
        self.socketManager = socketManager
    }

    func start(interval: TimeInterval = 30) {
        guard task == nil else { return }

        task = Task {
            while !Task.isCancelled {
                await runUpdateMetadata()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func runUpdateMetadata() async {
        let fingerprint = gatherFingerprintInfo()
        let postures = gatherPostureChecks()

        do {
            _ = try await socketManager.updateMetadata(fingerprint: fingerprint, postures: postures)
        } catch {
            print("Failed to push fingerprint and posture data state: \(error)")
        }
    }

    func gatherFingerprintInfo() -> Fingerprint {
        #if os(macOS)
            let username = NSUserName()

            let hostname = Host.current().localizedName ?? ""

            let osVersion = {
                let os = ProcessInfo.processInfo.operatingSystemVersion
                return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            }()

            let kernelVersion = runCommand(["uname", "-r"])

            #if arch(arm64)
                let architecture = "arm64"
            #elseif arch(x86_64)
                let architecture = "x86_64"
            #else
                let architecture = ""
            #endif

            let deviceModel =
                getIORegistryProperty("model")?.trimmingCharacters(in: .controlCharacters) ?? ""

            let serialNumber = getIORegistryProperty("IOPlatformSerialNumber") ?? ""

            let platformUUID = getIORegistryProperty("IOPlatformUUID") ?? ""

            let platformFingerprint = computePlatformFingerprint(
                arch: architecture, deviceModel: deviceModel, serialNumber: serialNumber,
                platformUUID: platformUUID)

            return Fingerprint(
                username: username,
                hostname: hostname,
                platform: "macos",
                osVersion: osVersion,
                kernelVersion: kernelVersion,
                arch: architecture,
                deviceModel: deviceModel,
                serialNumber: serialNumber,
                platformFingerprint: platformFingerprint,
            )
        #elseif os(iOS)
            let osVersion = {
                let os = ProcessInfo.processInfo.operatingSystemVersion
                return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            }()

            var uts = utsname()
            uname(&uts)

            let kernelVersion = withUnsafePointer(to: &uts.release) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }

            #if arch(arm64)
                let architecture = "arm64"
            #elseif arch(x86_64)
                let architecture = "x86_64"
            #else
                let architecture = ""
            #endif

            let modelIdentifier = withUnsafePointer(to: &uts.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }

            // Treat this persistent UUID as a serial number.
            let serialNumber = getOrCreatePersistentUUID()

            let platformFingerprint = computePlatformFingerprint(persistentUUID: serialNumber)

            return Fingerprint(
                username: "",
                hostname: UIDevice.current.name,
                platform: "ios",
                osVersion: UIDevice.current.systemVersion,
                kernelVersion: kernelVersion,
                arch: architecture,
                deviceModel: modelIdentifier,
                serialNumber: serialNumber,
                platformFingerprint: platformFingerprint,
            )
        #endif
    }

    func gatherPostureChecks() -> Postures {
        return Postures(
            autoUpdatesEnabled: queryAutoUpdatesEnabled(),
            biometricsEnabled: queryBiometricsEnabled(),
            diskEncrypted: queryDiskEncrypted(),
            firewallEnabled: queryFirewallEnabled(),
            // Secure Enclave and T2 are always available on iOS and macOS.
            tpmAvailable: true,

            macosSipEnabled: querySipEnabled(),
            macosGatekeeperEnabled: queryGatekeeperEnabled(),
            macosFirewallStealthMode: queryFirewallStealthMode(),
        )
    }

    private func queryAutoUpdatesEnabled() -> Bool {
        #if os(macOS)
            let output = runCommand(["softwareupdate", "--schedule"]).lowercased()
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

    private func queryDiskEncrypted() -> Bool {
        #if os(macOS)
            let output = runCommand(["fdesetup", "status"]).lowercased()
            return output.contains("filevault is on")
        #else
            return false
        #endif
    }

    private func queryFirewallEnabled() -> Bool {
        #if os(macOS)
            let output = runCommand([
                "/usr/bin/defaults", "read", "/Library/Preferences/com.apple.alf",
                "globalstate",
            ]).lowercased()
            // 0 = off, 1 = on for specific services, 2 = on for essential services
            return output != "0"
        #else
            return false
        #endif
    }

    private func querySipEnabled() -> Bool {
        #if os(macOS)
            let output = runCommand(["csrutil", "status"]).lowercased()
            return output.contains("enabled")
        #else
            return false
        #endif
    }

    private func queryGatekeeperEnabled() -> Bool {
        #if os(macOS)
            let output = runCommand(["spctl", "--status"]).lowercased()
            return output.contains("enabled")
        #else
            return false
        #endif
    }

    private func queryFirewallStealthMode() -> Bool {
        #if os(macOS)
            let output = runCommand([
                "/usr/libexec/ApplicationFirewall/socketfilterfw", "--getstealthmode",
            ]).lowercased()
            return output.contains("is on")
        #else
            return false
        #endif
    }

    #if os(macOS)
        private func runCommand(_ args: [String]) -> String {
            let task = Process()
            task.launchPath = "/usr/bin/env"
            task.arguments = args

            let pipe = Pipe()
            task.standardOutput = pipe
            task.launch()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
