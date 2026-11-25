/**
    @file CMakeBuildSystem.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief CMake and Ninja as build systems.
    @details
    CMake: a CMakeLists.txt in the root, with build/,
    cmake-build-debug/ or cmake-build-release/ as its build directory
    when one exists. A build directory not configured yet (no
    CMakeCache.txt) is configured before it is built; tests run with
    ctest, writing JUnit.

    Ninja: a build.ninja or rules.ninja in the root, build/ or out/. It
    builds with `ninja -C dir`, and tests with ctest when CMake made the
    directory (a CTestTestfile.cmake), else with ninja's test target.

    build.json's buildDirectory replaces the one detected. Both write
    compile_commands.json with their generators.
*/

import Foundation
import AemberLanguageKit

/// @brief A CMake project
struct CMakeBuildSystem: DetectableBuildSystem {

    static let identifier = "cmake"

    /// Folders a CMake build may be in, in the order they are searched
    static let buildDirectories = ["build", "cmake-build-debug", "cmake-build-release"]

    /// The build directory found, relative to the root; nil when none exists yet
    var buildDirectory: String?

    var displayName: String {
        PackStrings.text("CMake").localized
    }

    var buildFiles: [String] {
        ["CMakeLists.txt"]
    }

    static func detect(in projectRoot: URL) -> CMakeBuildSystem? {
        guard CMakeBuildSystem().buildFileURL(in: projectRoot) != nil else {
            return nil
        }
        let directory = buildDirectories.first { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(name).path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return CMakeBuildSystem(buildDirectory: directory)
    }

    func command(for action: BuildAction, in projectRoot: URL, config: BuildProjectConfig?, filter: String?, outputDirectory: URL, context: any BuildSystemContext) throws -> BuildCommand {
        let directory = config?.buildDirectory ?? buildDirectory ?? "build"
        if action == .build {
            var steps: [BuildStep] = []
            let cache = projectRoot.appendingPathComponent(directory).appendingPathComponent("CMakeCache.txt")
            if !FileManager.default.fileExists(atPath: cache.path) {
                steps.append(BuildStep(executable: "cmake", arguments: ["-S", ".", "-B", directory]))
            }
            steps.append(BuildStep(executable: "cmake", arguments: ["--build", directory]))
            return BuildCommand(steps: steps, environmentIdentifier: identifier)
        }
        return Self.ctestCommand(directory: directory, filter: filter, identifier: identifier, outputDirectory: outputDirectory)
    }

    func compilationDatabase(for projectURL: URL, context: any BuildSystemContext, onOutput: ((String) -> Void)?) async throws -> CompilationDatabaseOutput {
        .generated(try await CMakeGenerator(executablePath: context.toolPath("cmake")).generate(projectURL: projectURL, buildDirectory: buildDirectory, onOutput: onOutput))
    }

    /// @brief ctest's command, writing a JUnit report.
    /// @param directory The build directory, relative to the root
    /// @param filter The tests to run, nil for all
    /// @param identifier The environment's identifier
    /// @param outputDirectory Where the report goes
    /// @return The command
    static func ctestCommand(directory: String, filter: String?, identifier: String, outputDirectory: URL) -> BuildCommand {
        let report = outputDirectory.appendingPathComponent("junit.xml")
        var command = BuildCommand(steps: [BuildStep(executable: "ctest", arguments: ["--test-dir", directory, "--output-on-failure", "--output-junit", report.path] + (filter.map { ["-R", $0] } ?? []))], environmentIdentifier: identifier)
        command.junitReport = report
        return command
    }
}

/// @brief A Ninja build
struct NinjaBuildSystem: DetectableBuildSystem {

    static let identifier = "ninja"

    /// Folders a Ninja build may be in, relative to the project root
    /// (nil is the root itself), in the order they are searched
    static let buildDirectories: [String?] = [nil, "build", "out"]

    /// The folder with the build's files, relative to the root; nil is the root
    var buildDirectory: String?

    var displayName: String {
        PackStrings.text("Ninja").localized
    }

    /// The build's files, in its build directory
    var buildFiles: [String] {
        ["build.ninja", "rules.ninja"].map { name in buildDirectory.map { "\($0)/\(name)" } ?? name }
    }

    static func detect(in projectRoot: URL) -> NinjaBuildSystem? {
        buildDirectories.map { NinjaBuildSystem(buildDirectory: $0) }.first { $0.buildFileURL(in: projectRoot) != nil }
    }

    func command(for action: BuildAction, in projectRoot: URL, config: BuildProjectConfig?, filter: String?, outputDirectory: URL, context: any BuildSystemContext) throws -> BuildCommand {
        let directory = config?.buildDirectory ?? buildDirectory ?? "."
        if action == .build {
            return single("ninja", ["-C", directory])
        }
        let ctestFile = projectRoot.appendingPathComponent(directory).appendingPathComponent("CTestTestfile.cmake")
        guard FileManager.default.fileExists(atPath: ctestFile.path) else {
            return single("ninja", ["-C", directory, "test"])
        }
        return CMakeBuildSystem.ctestCommand(directory: directory, filter: filter, identifier: identifier, outputDirectory: outputDirectory)
    }

    func compilationDatabase(for projectURL: URL, context: any BuildSystemContext, onOutput: ((String) -> Void)?) async throws -> CompilationDatabaseOutput {
        .generated(try await NinjaGenerator(executablePath: context.toolPath("ninja")).generate(projectURL: projectURL, buildDirectory: buildDirectory, onOutput: onOutput))
    }
}
