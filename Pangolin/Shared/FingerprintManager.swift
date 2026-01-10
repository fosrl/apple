//
//  SocketManager.swift
//  Pangolin
//
//  Created by Varun Narravula on 1/6/2025.
//

import Combine
import Darwin
import Foundation
import IOKit
import os.log

@MainActor
class FingerprintManager: ObservableObject {
    @Published var fingerprint: [String: String] = [:]
    @Published var postures: [String: String] = [:]

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
        let username = NSUserName()

        let hostname = Host.current().localizedName ?? ""

        let osVersion = {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        }()

        let kernelVersion = runCommand(["uname", "-r"])

        let arch = runCommand(["uname", "-m"])

        let deviceModel =
            getIORegistryProperty("model")?.trimmingCharacters(in: .controlCharacters) ?? "unknown"

        let serialNumber = getIORegistryProperty("IOPlatformSerialNumber") ?? "unknown"

        return Fingerprint(
            username: username,
            hostname: hostname,
            platform: "macos",
            osVersion: osVersion,
            kernelVersion: kernelVersion,
            arch: arch,
            deviceModel: deviceModel,
            serialNumber: serialNumber
        )
    }

    func gatherPostureChecks() -> Postures {
        let firewallEnabled = {
            let output = runCommand([
                "/usr/bin/defaults", "read", "/Library/Preferences/com.apple.alf", "globalstate",
            ]).lowercased()
            // 0 = off, 1 = on for specific services, 2 = on for essential services
            return output != "0"
        }()

        let diskEncrypted = {
            let output = runCommand(["fdesetup", "status"]).lowercased()
            return output.contains("filevault is on")
        }()

        let sipEnabled = {
            let output = runCommand(["csrutil", "status"]).lowercased()
            return output.contains("enabled")
        }()

        // Auto updates
        let autoUpdatesEnabled = {
            let output = runCommand(["softwareupdate", "--schedule"]).lowercased()
            return output.contains("on")
        }()

        return Postures(
            firewallEnabled: firewallEnabled,
            diskEncrypted: diskEncrypted,
            sipEnabled: sipEnabled,
            autoUpdatesEnabled: autoUpdatesEnabled
        )
    }

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
}
