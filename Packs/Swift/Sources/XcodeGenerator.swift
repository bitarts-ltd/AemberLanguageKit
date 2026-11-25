/**
    @file XcodeGenerator.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Generates compilation database by parsing xcodebuild logs.
    @details
    Xcode doesn't have native compilation database support, so we parse
    the build log from xcodebuild to extract compiler invocations.
    This works for both .xcodeproj and .xcworkspace projects.

    Note: Modern Xcode (14+) no longer supports -dry-run or the legacy build
    system, so we run an actual build and parse the verbose output. It
    builds into a folder of its own under the user's Caches, emptied
    first so every file compiles and shows in the log, and left in place
    because the commands name headers and modules inside it. The
    project's own build products are not touched.
*/

import CryptoKit
import Foundation
import AemberLanguageKit

/// @brief Error types for Xcode generation.
/// @detail
/// No compile commands, and writing the database, are
/// CompilationDatabaseError's.
enum XcodeGeneratorError: Error, LocalizedError {
    case noProjectOrWorkspace
    case noSchemeAvailable
    case buildFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProjectOrWorkspace:
            return PackStrings.text("No .xcodeproj or .xcworkspace found").localized
        case .noSchemeAvailable:
            return PackStrings.text("No build scheme available").localized
        case .buildFailed(let output):
            return String(
                format: PackStrings.text("xcodebuild failed: %@").localized,
                output
            )
        }
    }
}

/// @brief Generates compilation database by parsing xcodebuild output.
struct XcodeGenerator {

    private let fileManager = FileManager.default

    /// Path to the xcodebuild executable, or nil to search for it
    private let executablePath: String?

    /// Holds each project's build folder
    private let derivedDataRoot: URL

    /// @brief Where projects' build folders go by default: the user's
    /// Caches, or a temporary folder while tests run
    static let defaultDerivedDataRoot: URL = {
        let environment = ProcessInfo.processInfo.environment
        let isRunningTests = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil || environment["XCTestSessionIdentifier"] != nil
        let base = isRunningTests
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("AemberTests-Caches")
            : FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Aember")
        return base.appendingPathComponent("XcodeDerivedData")
    }()

    /// @brief Create a generator.
    /// @param executablePath Path to the xcodebuild executable, or nil to
    /// locate it at run time
    /// @param derivedDataRoot The folder to keep projects' build folders
    /// in, or nil for the default
    /// @return Nothing
    init(executablePath: String? = nil, derivedDataRoot: URL? = nil) {
        self.executablePath = executablePath
        self.derivedDataRoot = derivedDataRoot ?? Self.defaultDerivedDataRoot
    }

    /// @brief The folder a project's compile-command builds go in.
    /// @param projectURL The project root directory
    /// @return The folder, named for the project and a hash of its path
    func derivedDataURL(for projectURL: URL) -> URL {
        let path = projectURL.standardizedFileURL.path
        let hash = SHA256.hash(data: Data(path.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return derivedDataRoot.appendingPathComponent(
            "\(projectURL.lastPathComponent)-\(hash)"
        )
    }

    /// @brief Generate compilation database for an Xcode project.
    /// @details
    /// Runs xcodebuild and parses the output to extract compiler invocations.
    /// Creates CompileCommand entries for each compilation. Note that this
    /// requires running an actual build since modern Xcode no longer supports
    /// the -dry-run flag.
    /// @param projectURL The project root directory
    /// @param workspace Optional workspace name
    /// @param project Optional project name
    /// @param scheme Optional scheme name; XcodeProjectLookup's if nil
    /// @param onOutput Optional callback for xcodebuild output
    /// @return URL of the generated compile_commands.json file
    func generate(
        projectURL: URL,
        workspace: String? = nil,
        project: String? = nil,
        scheme: String? = nil,
        onOutput: ((String) -> Void)? = nil
    ) async throws -> URL {
        // Determine workspace or project to use
        let (useWorkspace, useProject) = try determineProjectType(
            projectURL: projectURL,
            workspace: workspace,
            project: project
        )

        // Determine scheme
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
            PackStrings.text("Running xcodebuild to extract compilation commands (this may take a moment if the project needs to be built)…").localized
        )

        // Run xcodebuild build
        let buildOutput = try await runXcodebuild(
            projectURL: projectURL,
            workspace: useWorkspace,
            project: useProject,
            scheme: useScheme,
            onOutput: onOutput
        )

        // Parse build output
        let commands = parseCompilationCommands(
            from: buildOutput,
            projectURL: projectURL
        )

        guard !commands.isEmpty else {
            throw CompilationDatabaseError.noCompilationCommands
        }

        let destinationURL = try CompilationDatabaseFile.write(
            commands,
            projectURL: projectURL
        )

        onOutput?(PackStrings.text("Generated compilation database").localized)

        return destinationURL
    }

    // MARK: - Private Methods

    /// @brief URL of the xcodebuild executable to run.
    /// @return The injected path, or /usr/bin/xcodebuild by default
    private var xcodebuildURL: URL {
        return URL(
            fileURLWithPath: executablePath ?? "/usr/bin/xcodebuild"
        )
    }

    /// @brief Determine which workspace or project to build.
    /// @param projectURL The project root directory
    /// @param workspace The workspace to build, if given
    /// @param project The project to build, if given
    /// @return The given workspace, else the given project, else
    /// XcodeProjectLookup's choice
    /// @throws XcodeGeneratorError.noProjectOrWorkspace when there is
    /// none
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
            throw XcodeGeneratorError.noProjectOrWorkspace
        }
        return found
    }

    /// @brief Detect the scheme to build with XcodeProjectLookup.
    /// @param projectURL The project root directory
    /// @param workspace The workspace to build, if any
    /// @param project The project to build, if no workspace
    /// @param onOutput Optional callback, told the scheme chosen
    /// @return The scheme
    /// @throws XcodeGeneratorError.noSchemeAvailable when xcodebuild
    /// lists none
    private func detectScheme(
        projectURL: URL,
        workspace: String?,
        project: String?,
        onOutput: ((String) -> Void)?
    ) throws -> String {
        let lookup = XcodeProjectLookup(xcodebuildPath: xcodebuildURL.path)
        guard let scheme = lookup.scheme(
            in: projectURL, workspace: workspace, project: project
        ) else {
            throw XcodeGeneratorError.noSchemeAvailable
        }

        onOutput?(
            String(
                format: PackStrings.text("Using scheme: %@").localized,
                scheme
            )
        )

        return scheme
    }

    /// @brief Run a full xcodebuild build in the generator's own folder.
    /// @details
    /// Empties the project's build folder, builds into it and captures
    /// the output. Modern Xcode (14+) no longer supports -dry-run, so we
    /// must run a real build. Starting empty ensures that every file's
    /// compiler command appears in the build output, without cleaning
    /// the user's own build products.
    private func runXcodebuild(
        projectURL: URL,
        workspace: String?,
        project: String?,
        scheme: String,
        onOutput: ((String) -> Void)?
    ) async throws -> String {
        let derivedData = derivedDataURL(for: projectURL)
        if fileManager.fileExists(atPath: derivedData.path) {
            try fileManager.removeItem(at: derivedData)
        }

        // Load environment from .aember/xcode-env if it exists
        let xcodeEnv = BuildEnvironmentLoader.loadEnvironment(
            projectURL: projectURL,
            identifier: "xcode"
        )

        onOutput?(
            PackStrings.text("Building to extract compilation commands…").localized
        )

        let process = Process()
        process.executableURL = xcodebuildURL

        var args: [String] = []

        if let ws = workspace {
            args.append(contentsOf: ["-workspace", ws])
        } else if let proj = project {
            args.append(contentsOf: ["-project", proj])
        }

        //
        // Run actual build - modern Xcode doesn't support -dry-run.
        // Use Debug configuration for faster builds.
        //
        args.append(contentsOf: [
            "-scheme", scheme,
            "-configuration", "Debug",
            "-derivedDataPath", derivedData.path,
            "build"
        ])

        process.arguments = args
        process.currentDirectoryURL = projectURL
        process.environment = xcodeEnv

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let (outputData, errorData) = await process.readToEnd(
            output: outputPipe,
            error: errorPipe
        )

        if process.terminationStatus != 0 {
            let error = String(data: errorData, encoding: .utf8)
                ?? PackStrings.text("Unknown error").localized
            throw XcodeGeneratorError.buildFailed(error)
        }

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        return output + errorOutput
    }

    /// @brief Parse compilation commands from xcodebuild output.
    /// @details
    /// Modern xcodebuild output uses file lists (@path/to.SwiftFileList) instead
    /// of listing each file on the command line. This method handles both the
    /// legacy format and the modern format.
    func parseCompilationCommands(
        from output: String,
        projectURL: URL
    ) -> [CompileCommand] {
        var commands: [CompileCommand] = []
        let lines = output.components(separatedBy: .newlines)
        var currentDirectory = projectURL.path

        for line in lines {
            // Update working directory from -working-directory flag
            if let range = line.range(of: "-working-directory\\s+(\\S+)",
                                       options: .regularExpression) {
                let match = String(line[range])
                let dir = match.replacingOccurrences(
                    of: "-working-directory ",
                    with: ""
                )
                currentDirectory = dir
            }

            // Look for Swift compiler invocations with file lists
            if line.contains("swiftc") && line.contains(" -c ") {
                let parsedCommands = parseSwiftCompilerCommand(
                    line: line,
                    directory: currentDirectory
                )
                commands.append(contentsOf: parsedCommands)
            }

            // Look for clang/clang++ invocations (C/C++/ObjC)
            if (line.contains("/clang ") || line.contains("/clang++ ")) &&
                line.contains(" -c ") {
                if let command = parseClangCompilerCommand(
                    line: line,
                    directory: currentDirectory
                ) {
                    commands.append(command)
                }
            }
        }

        return commands
    }

    /// @brief Parse a Swift compiler command line.
    /// @details
    /// Modern swiftc commands reference source files via @path/to.SwiftFileList
    /// files. This method reads those file lists to extract individual source
    /// files.
    private func parseSwiftCompilerCommand(
        line: String,
        directory: String
    ) -> [CompileCommand] {
        var commands: [CompileCommand] = []

        // Strip builtin- prefix if present
        var commandLine = line
        if let range = line.range(of: "builtin-[A-Za-z-]+ -- ",
                                   options: .regularExpression) {
            commandLine = String(line[range.upperBound...])
        }

        // Find SwiftFileList reference
        let fileListPattern = "@(\\S+\\.SwiftFileList)"
        guard let regex = try? NSRegularExpression(pattern: fileListPattern),
              let match = regex.firstMatch(
                in: commandLine,
                range: NSRange(commandLine.startIndex..., in: commandLine)
              ) else {
            return commands
        }

        let nsRange = match.range(at: 1)
        let nsString = commandLine as NSString
        let fileListPath = nsString.substring(with: nsRange)

        // Read source files from the file list
        guard let fileListContents = try? String(
            contentsOfFile: fileListPath,
            encoding: .utf8
        ) else {
            return commands
        }

        let sourceFiles = fileListContents.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Create a command for each source file
        for sourceFile in sourceFiles {
            let command = CompileCommand(
                directory: directory,
                command: commandLine.trimmingCharacters(in: .whitespaces),
                file: sourceFile,
                arguments: nil,
                output: nil
            )
            commands.append(command)
        }

        return commands
    }

    /// @brief Parse a clang/clang++ compiler command line.
    private func parseClangCompilerCommand(
        line: String,
        directory: String
    ) -> CompileCommand? {
        // Extract source file after -c flag. The lookahead makes the
        // extension match the whole suffix, so x.cpp is not cut to x.c.
        let pattern = "-c\\s+(\\S+\\.(?:c|cpp|cc|cxx|m|mm))(?=\\s|$)"

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
              ) else {
            return nil
        }

        let nsRange = match.range(at: 1)
        let nsString = line as NSString
        let sourceFile = nsString.substring(with: nsRange)

        return CompileCommand(
            directory: directory,
            command: line.trimmingCharacters(in: .whitespaces),
            file: sourceFile,
            arguments: nil,
            output: nil
        )
    }
}
