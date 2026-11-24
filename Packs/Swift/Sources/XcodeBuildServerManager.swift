/**
    @file XcodeBuildServerManager.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief
    Manages xcode-build-server integration for Xcode projects.
    @details
    xcode-build-server implements the Build Server Protocol (BSP),
    allowing sourcekit-lsp to query Xcode's build system directly for
    index data. This avoids the need to generate a compilation database
    by running a full xcodebuild. When a buildServer.json file is
    present in the project root, sourcekit-lsp automatically connects
    to the build server for full LSP support.

    Install xcode-build-server via: brew install xcode-build-server
*/

import Foundation
import AemberLanguageKit

/// @brief Error types for xcode-build-server operations.
enum XcodeBuildServerError: Error, LocalizedError {
    case notInstalled
    case configFailed(String)
    case noProjectOrWorkspace
    case noSchemeAvailable

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return PackStrings.text("xcode-build-server is not installed. Install via: brew install xcode-build-server").localized
        case .configFailed(let output):
            return String(
                format: PackStrings.text("xcode-build-server config failed: %@").localized,
                output
            )
        case .noProjectOrWorkspace:
            return PackStrings.text("No .xcodeproj or .xcworkspace found").localized
        case .noSchemeAvailable:
            return PackStrings.text("No build scheme available").localized
        }
    }
}

/// @brief Manages xcode-build-server for Xcode project LSP support.
struct XcodeBuildServerManager {

    private let fileManager = FileManager.default

    /// Path to xcode-build-server, or nil to search for it
    private let executablePath: String?

    /// Path to xcodebuild, used to list schemes
    private let xcodebuildPath: String

    /// @brief Create a manager.
    /// @param executablePath Path to xcode-build-server, or nil to search
    /// PATH and well-known locations. When set, only this path is used.
    /// @param xcodebuildPath Path to xcodebuild for scheme detection
    /// @return Nothing
    init(
        executablePath: String? = nil,
        xcodebuildPath: String = "/usr/bin/xcodebuild"
    ) {
        self.executablePath = executablePath
        self.xcodebuildPath = xcodebuildPath
    }

    /// @brief Check if xcode-build-server is installed.
    /// @return Path to the executable if found, nil otherwise
    func findExecutable() -> URL? {
        if let executablePath {
            return fileManager.isExecutableFile(atPath: executablePath)
                ? URL(fileURLWithPath: executablePath)
                : nil
        }

        let searchPaths = [
            "/opt/homebrew/bin/xcode-build-server",
            "/usr/local/bin/xcode-build-server"
        ]

        // Try which first
        let whichProcess = Process()
        whichProcess.executableURL =
            URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["xcode-build-server"]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        try? whichProcess.run()
        whichProcess.waitForExit()

        if whichProcess.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        // Fall back to well-known locations
        for path in searchPaths {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    /// @brief Generate buildServer.json for an Xcode project.
    /// @detail
    /// Runs xcode-build-server config to create a buildServer.json
    /// file in the project root. sourcekit-lsp will discover this file
    /// automatically and use xcode-build-server as its build server,
    /// getting full index data from Xcode's build system.
    /// @param projectURL The project root directory
    /// @param workspace Optional workspace name (e.g., "Foo.xcworkspace")
    /// @param project Optional project name (e.g., "Foo.xcodeproj")
    /// @param scheme Optional scheme name; XcodeProjectLookup's if nil
    /// @param onOutput Optional callback for status messages
    /// @return URL of the generated buildServer.json file
    func configure(
        projectURL: URL,
        workspace: String? = nil,
        project: String? = nil,
        scheme: String? = nil,
        onOutput: ((String) -> Void)? = nil
    ) async throws -> URL {
        guard let executableURL = findExecutable() else {
            throw XcodeBuildServerError.notInstalled
        }

        // Determine workspace or project path
        let (useWorkspace, useProject) = try determineProjectType(
            projectURL: projectURL,
            workspace: workspace,
            project: project
        )

        // Detect scheme if not provided
        let useScheme: String
        if let providedScheme = scheme {
            useScheme = providedScheme
        } else {
            useScheme = try detectScheme(
                projectURL: projectURL,
                workspace: useWorkspace,
                project: useProject,
                onOutput: onOutput
            )
        }

        onOutput?(
            String(
                format: PackStrings.text("Configuring xcode-build-server with scheme: %@").localized,
                useScheme
            )
        )

        // Build arguments for xcode-build-server config
        var args = ["config", "-scheme", useScheme]

        if let ws = useWorkspace {
            let workspacePath = projectURL
                .appendingPathComponent(ws).path
            args.append(contentsOf: ["-workspace", workspacePath])
        } else if let proj = useProject {
            let projectPath = projectURL
                .appendingPathComponent(proj).path
            args.append(contentsOf: ["-project", projectPath])
        }

        // Run xcode-build-server config
        let process = Process()
        process.executableURL = executableURL
        process.arguments = args
        process.currentDirectoryURL = projectURL

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        // Drain both pipes before waiting, so a chatty tool cannot
        // block on a full pipe
        let (outputData, errorData) = await process.readToEnd(
            output: outputPipe,
            error: errorPipe
        )

        if process.terminationStatus != 0 {
            let errorOutput = String(
                data: errorData,
                encoding: .utf8
            ) ?? ""
            let stdOutput = String(
                data: outputData,
                encoding: .utf8
            ) ?? ""
            throw XcodeBuildServerError.configFailed(
                errorOutput.isEmpty ? stdOutput : errorOutput
            )
        }

        let buildServerJSON = projectURL
            .appendingPathComponent("buildServer.json")

        guard fileManager.fileExists(
            atPath: buildServerJSON.path
        ) else {
            throw XcodeBuildServerError.configFailed(
                PackStrings.text("buildServer.json was not created").localized
            )
        }

        onOutput?(
            PackStrings.text("xcode-build-server configured successfully. sourcekit-lsp will use Xcode's build system for indexing.").localized
        )

        return buildServerJSON
    }

    // MARK: - Private Methods

    /// @brief Determine which workspace or project to configure.
    /// @param projectURL The project root directory
    /// @param workspace The workspace, if given
    /// @param project The project, if given
    /// @return The given workspace, else the given project, else
    /// XcodeProjectLookup's choice
    /// @throws XcodeBuildServerError.noProjectOrWorkspace when there
    /// is none
    private func determineProjectType(
        projectURL: URL,
        workspace: String?,
        project: String?
    ) throws -> (workspace: String?, project: String?) {
        if let ws = workspace {
            return (ws, nil)
        }
        if let proj = project {
            return (nil, proj)
        }
        guard let found = XcodeProjectLookup.container(in: projectURL) else {
            throw XcodeBuildServerError.noProjectOrWorkspace
        }
        return found
    }

    /// @brief Detect the scheme with XcodeProjectLookup.
    /// @param projectURL The project root directory
    /// @param workspace The workspace, if any
    /// @param project The project, if no workspace
    /// @param onOutput Optional callback, told the scheme chosen
    /// @return The scheme
    /// @throws XcodeBuildServerError.noSchemeAvailable when xcodebuild
    /// lists none
    private func detectScheme(
        projectURL: URL,
        workspace: String?,
        project: String?,
        onOutput: ((String) -> Void)?
    ) throws -> String {
        let lookup = XcodeProjectLookup(xcodebuildPath: xcodebuildPath)
        guard let scheme = lookup.scheme(
            in: projectURL, workspace: workspace, project: project
        ) else {
            throw XcodeBuildServerError.noSchemeAvailable
        }

        onOutput?(
            String(
                format: PackStrings.text("Detected scheme: %@").localized,
                scheme
            )
        )

        return scheme
    }
}
