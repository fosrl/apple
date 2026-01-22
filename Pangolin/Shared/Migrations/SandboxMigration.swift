//
//  SandboxMigration.swift
//  Pangolin
//
//  Created on 1/14/26.
//

import Foundation
import os.log

#if os(macOS)
/// Handles migration of data from sandboxed container to non-sandboxed location.
/// This migration is needed when upgrading from a sandboxed version to a non-sandboxed version.
enum SandboxMigration {
    private static let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin"
        return OSLog(subsystem: subsystem, category: "SandboxMigration")
    }()

    /// Migrates data from sandboxed location to non-sandboxed location if needed.
    /// This is idempotent and safe to call multiple times.
    /// - Returns: `true` if migration was attempted (regardless of success), `false` if no migration was needed
    static func migrateIfNeeded() -> Bool {
        guard let sandboxedPath = getSandboxedPath() else {
            // Sandboxed path doesn't exist, nothing to migrate
            return false
        }

        let nonSandboxedPath = getNonSandboxedPath()

        // Ensure non-sandboxed directory exists
        do {
            try FileManager.default.createDirectory(
                at: nonSandboxedPath,
                withIntermediateDirectories: true
            )
        } catch {
            os_log(
                "Failed to create non-sandboxed directory: %{public}@",
                log: logger,
                type: .error,
                error.localizedDescription
            )
            return false
        }

        var migrationAttempted = false

        // Migrate accounts.json
        let accountsFile = "accounts.json"
        if migrateFile(
            fileName: accountsFile,
            from: sandboxedPath,
            to: nonSandboxedPath
        ) {
            migrationAttempted = true
        }

        // Migrate pangolin.json
        let configFile = "pangolin.json"
        if migrateFile(
            fileName: configFile,
            from: sandboxedPath,
            to: nonSandboxedPath
        ) {
            migrationAttempted = true
        }

        if migrationAttempted {
            os_log(
                "Sandbox migration completed successfully",
                log: logger,
                type: .info
            )
        }

        return migrationAttempted
    }

    // MARK: - Private Helpers

    /// Gets the sandboxed container path for the app.
    /// Returns `nil` if the path doesn't exist or can't be determined.
    private static func getSandboxedPath() -> URL? {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let containerPath = homeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("net.pangolin.Pangolin")
            .appendingPathComponent("Data")
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Pangolin", isDirectory: true)

        // Check if the sandboxed path exists
        guard FileManager.default.fileExists(atPath: containerPath.path) else {
            return nil
        }

        return containerPath
    }

    /// Gets the non-sandboxed Application Support path.
    private static func getNonSandboxedPath() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        return appSupport.appendingPathComponent("Pangolin", isDirectory: true)
    }

    /// Migrates a single file from sandboxed to non-sandboxed location.
    /// Only migrates if the file exists in sandboxed location and doesn't exist in non-sandboxed location.
    /// - Parameters:
    ///   - fileName: Name of the file to migrate
    ///   - from: Source directory (sandboxed)
    ///   - to: Destination directory (non-sandboxed)
    /// - Returns: `true` if migration was attempted, `false` otherwise
    private static func migrateFile(
        fileName: String,
        from sourceDir: URL,
        to destDir: URL
    ) -> Bool {
        let sourceFile = sourceDir.appendingPathComponent(fileName)
        let destFile = destDir.appendingPathComponent(fileName)

        // Check if source file exists
        guard FileManager.default.fileExists(atPath: sourceFile.path) else {
            return false
        }

        // Don't overwrite existing destination file
        guard !FileManager.default.fileExists(atPath: destFile.path) else {
            os_log(
                "Skipping migration of %{public}@ - file already exists in destination",
                log: logger,
                type: .info,
                fileName
            )
            return false
        }

        // Copy the file
        do {
            try FileManager.default.copyItem(at: sourceFile, to: destFile)
            os_log(
                "Successfully migrated %{public}@ from sandboxed location",
                log: logger,
                type: .info,
                fileName
            )
            return true
        } catch {
            os_log(
                "Failed to migrate %{public}@: %{public}@",
                log: logger,
                type: .error,
                fileName,
                error.localizedDescription
            )
            return false
        }
    }
}
#endif
