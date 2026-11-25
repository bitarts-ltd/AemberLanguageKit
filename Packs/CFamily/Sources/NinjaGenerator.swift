/**
    @file NinjaGenerator.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Generates compilation database using Ninja's native support.
    @details
    Ninja build system has built-in support for compilation database
    export via the `-t compdb` tool. This generator runs it in the build
    directory (the one given, else the first of
    `NinjaBuildSystem.buildDirectories` with a build.ninja or
    rules.ninja, as the detector finds it) and writes what it prints to
    .aember/compile_commands.json.
*/

import Foundation
import AemberLanguageKit

/// @brief Error types for Ninja generation.
/// @detail
/// ninja missing, no compile commands, and writing the database, are
/// CompilationDatabaseError's.
enum NinjaGeneratorError: Error, LocalizedError {
    case buildDirectoryNotFound(URL)
    case ninjaCommandFailed(String)

    var errorDescription: String? {
        switch self {
        case .buildDirectoryNotFound(let url):
            return String(
                format: PackStrings.text("Ninja build directory not found at %@").localized,
                url.path
            )
        case .ninjaCommandFailed(let output):
            return String(
                format: PackStrings.text("Ninja compdb command failed: %@").localized,
                output
            )
        }
    }
}

/// @brief Generates compilation database using Ninja.
struct NinjaGenerator {

    private let fileManager = FileManager.default

    /// Path to the ninja executable, or nil to search for it
    private let executablePath: String?

    /// @brief Create a generator.
    /// @param executablePath Path to the ninja executable, or nil to
    /// locate it at run time
    /// @return Nothing
    init(executablePath: String? = nil) {
        self.executablePath = executablePath
    }

    /// @brief Generate compilation database for a Ninja project.
    /// @details
    /// Runs ninja -t compdb to export compilation database in JSON
    /// format, then writes it to .aember/compile_commands.json.
    /// @param projectURL The project root directory
    /// @param buildDirectory Optional build directory name
    /// @param onOutput Optional callback for ninja output lines
    /// @return URL of the generated compile_commands.json file
    func generate(
        projectURL: URL,
        buildDirectory: String? = nil,
        onOutput: ((String) -> Void)? = nil
    ) async throws -> URL {
        // Determine build directory
        let buildDir: URL
        if let buildDirName = buildDirectory {
            buildDir = projectURL.appendingPathComponent(buildDirName)
        } else {
            // Look for build.ninja in project root or common build directories
            buildDir = try findBuildDirectory(in: projectURL)
        }

        // Verify build directory exists
        guard fileManager.fileExists(atPath: buildDir.path) else {
            throw NinjaGeneratorError.buildDirectoryNotFound(buildDir)
        }

        onOutput?(
            PackStrings.text("Running ninja to generate compilation database…").localized
        )

        // Run ninja -t compdb
        let jsonOutput = try await runNinjaCompdb(
            projectURL: projectURL,
            buildDirURL: buildDir,
            onOutput: onOutput
        )

        // Validate output
        guard !jsonOutput.isEmpty else {
            throw CompilationDatabaseError.noCompilationCommands
        }

        let destinationURL = try CompilationDatabaseFile.write(
            Data(jsonOutput.utf8),
            projectURL: projectURL
        )
        onOutput?(
            PackStrings.text("Generated compilation database").localized
        )
        return destinationURL
    }

    // MARK: - Private Methods

    /// @brief Find the build directory with the Ninja build's files.
    /// @param projectURL The project root directory
    /// @return URL of the build directory
    private func findBuildDirectory(in projectURL: URL) throws -> URL {
        for directory in NinjaBuildSystem.buildDirectories {
            if NinjaBuildSystem(buildDirectory: directory).buildFileURL(in: projectURL) != nil {
                return directory.map {
                    projectURL.appendingPathComponent($0)
                } ?? projectURL
            }
        }
        throw NinjaGeneratorError.buildDirectoryNotFound(projectURL)
    }

    /// @brief Run ninja -t compdb command.
    /// @param projectURL The project root, for its build environment
    /// @param buildDirURL The build directory URL
    /// @param onOutput Optional callback for output
    /// @return JSON output as string
    private func runNinjaCompdb(
        projectURL: URL,
        buildDirURL: URL,
        onOutput: ((String) -> Void)?
    ) async throws -> String {
        // Find ninja executable
        guard let ninjaPath = executablePath
            ?? ExecutableFinder.findExecutable(named: "ninja") else {
            throw CompilationDatabaseError.toolNotFound("ninja")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ninjaPath)
        process.arguments = ["-C", buildDirURL.path, "-t", "compdb"]

        // Load environment from .aember/ninja-env if it exists
        process.environment = BuildEnvironmentLoader.loadEnvironment(
            projectURL: projectURL,
            identifier: "ninja"
        )

        // Set up output pipes
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Run process
        do {
            try process.run()

            // Drain stdout (contains JSON) and stderr, then wait
            let (outputData, errorData) = await process.readToEnd(
                output: outputPipe,
                error: errorPipe
            )

            guard let jsonOutput = String(data: outputData, encoding: .utf8) else {
                throw NinjaGeneratorError.ninjaCommandFailed("Invalid UTF-8 output")
            }

            // Report stderr output, if any
            if let errorOutput = String(data: errorData, encoding: .utf8),
               !errorOutput.isEmpty {
                onOutput?(errorOutput)
            }

            // Check exit status
            if process.terminationStatus != 0 {
                let errorMessage = String(data: errorData, encoding: .utf8)
                    ?? PackStrings.text("Unknown error").localized
                throw NinjaGeneratorError.ninjaCommandFailed(errorMessage)
            }

            return jsonOutput
        } catch let error as NinjaGeneratorError {
            throw error
        } catch {
            throw NinjaGeneratorError.ninjaCommandFailed(error.localizedDescription)
        }
    }
}
