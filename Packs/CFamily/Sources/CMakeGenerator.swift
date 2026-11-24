/**
    @file CMakeGenerator.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Generates compilation database using CMake's native support.
    @details
    CMake natively supports compilation database generation via the
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON flag. This generator runs cmake
    to configure the project in its build directory (made if missing),
    with the project's cmake build environment, and copies the generated
    compile_commands.json to .aember/. A cache left by the project at
    another path is cleared and the configuration run again.
*/

import Foundation
import AemberLanguageKit

/// @brief Error types for CMake generation.
/// @detail
/// cmake missing, and writing the database, are
/// CompilationDatabaseError's.
enum CMakeGeneratorError: Error, LocalizedError {
    case buildDirectoryCreationFailed(URL)
    case cmakeConfigurationFailed(String)
    case compilationDatabaseNotFound(URL)

    var errorDescription: String? {
        switch self {
        case .buildDirectoryCreationFailed(let url):
            return String(
                format: PackStrings.text("Failed to create build directory at %@").localized,
                url.path
            )
        case .cmakeConfigurationFailed(let output):
            return String(
                format: PackStrings.text("CMake configuration failed: %@").localized,
                output
            )
        case .compilationDatabaseNotFound(let url):
            return String(
                format: PackStrings.text("compile_commands.json not found at %@").localized,
                url.path
            )
        }
    }
}

/// @brief Generates compilation database using CMake.
struct CMakeGenerator {

    private let fileManager = FileManager.default

    /// Path to the cmake executable, or nil to search for it
    private let executablePath: String?

    /// @brief Create a generator.
    /// @param executablePath Path to the cmake executable, or nil to
    /// locate it at run time
    /// @return Nothing
    init(executablePath: String? = nil) {
        self.executablePath = executablePath
    }

    /// @brief Generate compilation database for a CMake project.
    /// @details
    /// Runs cmake with -DCMAKE_EXPORT_COMPILE_COMMANDS=ON to generate
    /// compile_commands.json in the build directory, then copies it to
    /// .aember/compile_commands.json.
    /// @param projectURL The project root directory
    /// @param buildDirectory Optional build directory name (default: "build")
    /// @param onOutput Optional callback for cmake output lines
    /// @return URL of the generated compile_commands.json file
    func generate(
        projectURL: URL,
        buildDirectory: String? = nil,
        onOutput: ((String) -> Void)? = nil
    ) async throws -> URL {
        // Determine build directory
        let buildDir = buildDirectory ?? "build"
        let buildDirURL = projectURL.appendingPathComponent(buildDir)

        // Create build directory if it doesn't exist
        if !fileManager.fileExists(atPath: buildDirURL.path) {
            do {
                try fileManager.createDirectory(
                    at: buildDirURL,
                    withIntermediateDirectories: true
                )

                onOutput?(String(
                    format: PackStrings.text("Created build directory: %@").localized,
                    buildDir
                ))
            } catch {
                throw CMakeGeneratorError.buildDirectoryCreationFailed(buildDirURL)
            }
        }

        // Run cmake configuration
        do {
            try await runCMake(
                projectURL: projectURL,
                buildDirURL: buildDirURL,
                onOutput: onOutput
            )
        } catch CMakeGeneratorError.cmakeConfigurationFailed(let output) {
            // Check if error is due to stale cache from different source directory
            // l10n-exempt-begin: CMake's English output
            if output.contains("CMakeCache.txt directory") &&
               output.contains("is different than the directory") {
                // l10n-exempt-end
                onOutput?(
                    PackStrings.text("Detected stale CMake cache, cleaning build directory…").localized
                )

                // Clean CMake cache files
                try cleanCMakeCache(in: buildDirURL)

                // Retry cmake configuration
                try await runCMake(
                    projectURL: projectURL,
                    buildDirURL: buildDirURL,
                    onOutput: onOutput
                )
            } else {
                // Re-throw if it's a different error
                throw CMakeGeneratorError.cmakeConfigurationFailed(output)
            }
        }

        // Locate generated compile_commands.json
        let generatedURL = buildDirURL.appendingPathComponent("compile_commands.json")

        guard fileManager.fileExists(atPath: generatedURL.path) else {
            throw CMakeGeneratorError.compilationDatabaseNotFound(generatedURL)
        }

        // Copy to .aember directory
        let data: Data
        do {
            data = try Data(contentsOf: generatedURL)
        } catch {
            throw CompilationDatabaseError.writeError(error)
        }
        let destinationURL = try CompilationDatabaseFile.write(
            data,
            projectURL: projectURL
        )
        onOutput?(
            PackStrings.text("Copied compilation database to .aember directory").localized
        )
        return destinationURL
    }

    // MARK: - Private Methods

    /// @brief Clean CMake cache files from the build directory.
    /// @detail
    /// Removes CMakeCache.txt and CMakeFiles directory to allow cmake to
    /// reconfigure from scratch. This is necessary when the project has been
    /// moved to a different location or the cache is stale.
    /// @param buildDirURL The build directory URL
    /// @return Nothing
    private func cleanCMakeCache(in buildDirURL: URL) throws {
        // Remove CMakeCache.txt
        let cacheFile = buildDirURL.appendingPathComponent("CMakeCache.txt")
        if fileManager.fileExists(atPath: cacheFile.path) {
            try fileManager.removeItem(at: cacheFile)
        }

        // Remove CMakeFiles directory
        let cmakeFilesDir = buildDirURL.appendingPathComponent("CMakeFiles")
        if fileManager.fileExists(atPath: cmakeFilesDir.path) {
            try fileManager.removeItem(at: cmakeFilesDir)
        }
    }

    /// @brief Run cmake configuration command.
    /// @param projectURL The project root directory
    /// @param buildDirURL The build directory URL
    /// @param onOutput Optional callback for cmake output
    private func runCMake(
        projectURL: URL,
        buildDirURL: URL,
        onOutput: ((String) -> Void)?
    ) async throws {
        // Find cmake executable
        guard let cmakePath = executablePath
            ?? ExecutableFinder.findExecutable(named: "cmake") else {
            throw CompilationDatabaseError.toolNotFound("cmake")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cmakePath)
        process.arguments = [
            "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
            projectURL.path
        ]
        process.currentDirectoryURL = buildDirURL

        // Load environment from .aember/cmake-env if it exists
        process.environment = BuildEnvironmentLoader.loadEnvironment(
            projectURL: projectURL,
            identifier: "cmake"
        )

        // Set up output pipes
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Read output in background, streaming lines as they arrive.
        // Each handler leaves the group at EOF so all output is
        // collected before the exit status is checked.
        let outputLines = PipeLines()
        let errorLines = PipeLines()
        let eofGroup = DispatchGroup()

        func installHandler(on fileHandle: FileHandle, lines: PipeLines) {
            eofGroup.enter()
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData

                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if let last = lines.finish() {
                        last.forEach { onOutput?($0) }
                        eofGroup.leave()
                    }
                    return
                }

                lines.receive(data).forEach { onOutput?($0) }
            }
        }

        installHandler(
            on: outputPipe.fileHandleForReading,
            lines: outputLines
        )
        installHandler(
            on: errorPipe.fileHandleForReading,
            lines: errorLines
        )

        // Run process
        do {
            try process.run()
            await process.exited()

            // Wait until both pipes reach EOF so no trailing output is
            // lost
            await withCheckedContinuation { continuation in
                eofGroup.notify(queue: .global()) {
                    continuation.resume()
                }
            }

            // Check exit status
            if process.terminationStatus != 0 {
                let allOutput = (outputLines.lines + errorLines.lines)
                    .joined(separator: "\n")
                throw CMakeGeneratorError.cmakeConfigurationFailed(allOutput)
            }
        } catch let error as CMakeGeneratorError {
            throw error
        } catch {
            throw CMakeGeneratorError.cmakeConfigurationFailed(error.localizedDescription)
        }
    }
}

/// @brief Lines read from one of cmake's output pipes
/// @detail
/// Filled by the pipe's readability handler, which runs on a background
/// queue, and read once cmake has exited, so access is locked. A read can
/// end anywhere, even inside a multi-byte character, so bytes are held
/// back until their line ends.
private final class PipeLines: @unchecked Sendable {

    /// @brief Guards the lines, the unfinished line and the EOF flag
    private let lock = NSLock()

    /// @brief Lines read so far
    private var received: [String] = []

    /// @brief Bytes of the line still being read
    private var partialLine = Data()

    /// @brief Whether the pipe has reached EOF
    private var reachedEOF = false

    /// @brief Lines read so far, in order
    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// @brief Takes a chunk of output and cuts off the lines it finishes
    /// @detail
    /// Lines end at a line feed or carriage return, neither of which can
    /// occur inside a UTF-8 sequence. Empty lines are dropped, which also
    /// covers a CR LF pair, even one split across two reads.
    /// @param data The bytes read
    /// @return The lines this chunk finished, in order
    func receive(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        partialLine.append(data)
        var finished: [String] = []
        var start = partialLine.startIndex
        while let end = partialLine[start...].firstIndex(
            where: { $0 == 0x0A || $0 == 0x0D }
        ) {
            if end > start {
                finished.append(String(
                    decoding: partialLine[start..<end], as: UTF8.self
                ))
            }
            start = end + 1
        }
        partialLine.removeSubrange(partialLine.startIndex..<start)
        received.append(contentsOf: finished)
        return finished
    }

    /// @brief Notes that the pipe reached EOF
    /// @return The last, unterminated line if there was one (or an empty
    /// array) the first time it is called, nil after that
    func finish() -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        guard !reachedEOF else { return nil }
        reachedEOF = true
        guard !partialLine.isEmpty else { return [] }
        let last = String(decoding: partialLine, as: UTF8.self)
        partialLine = Data()
        received.append(last)
        return [last]
    }
}
