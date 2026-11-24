/**
    @file CMakeGeneratorTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Tests for CMakeGenerator.
    @details
    Runs the generator against a fake cmake shell script that records
    its arguments and environment and writes a canned
    compile_commands.json, so no real cmake is needed. Covers build
    directory creation, copying the database into .aember, failures,
    recovery from a stale CMake cache, and output cut across reads.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import CFamilyPack

@Suite("CMakeGenerator")
struct CMakeGeneratorTests {

    /// Canned compilation database written by the fake cmake
    private static let database =
        #"[{"directory":"/x","command":"cc -c a.c","file":"a.c"}]"#

    /// Fake cmake: records arguments and environment, then writes the
    /// database into its working directory (the build directory)
    private static let succeedingScript = """
        printf '%s\\n' "$@" > ../cmake-args.txt
        printf '%s' "$AEMBER_TEST_CMAKE" > ../cmake-env.txt
        echo "-- Configuring done"
        echo "-- warning on stderr" >&2
        printf '%s' '\(database)' > compile_commands.json
        """

    /// @brief Create a fixture project with a fake cmake.
    /// @param script Body of the fake cmake script
    /// @return The fixture and a generator that runs the fake
    private func makeProject(
        script: String = CMakeGeneratorTests.succeedingScript
    ) throws -> (BuildSystemFixture, CMakeGenerator) {
        let fixture = try BuildSystemFixture()
        try fixture.write("CMakeLists.txt", "project(Test C)\n")
        let cmake = try fixture.writeScript("tools/cmake", script)
        return (fixture, CMakeGenerator(executablePath: cmake.path))
    }

    /// @brief Generation creates the build directory, runs cmake there,
    /// and copies the database into .aember.
    @Test func generatesDatabase() async throws {
        let (fixture, generator) = try makeProject()
        let output = OutputLines()
        let result = try await generator.generate(
            projectURL: fixture.root,
            onOutput: output.append
        )
        #expect(result == fixture.url(".aember/compile_commands.json"))
        #expect(try fixture.read(".aember/compile_commands.json")
            == Self.database)
        #expect(fixture.exists("build/compile_commands.json"))
        #expect(output.lines.contains("Created build directory: build"))
        #expect(output.lines.contains(
            "Copied compilation database to .aember directory"
        ))
    }

    /// @brief cmake gets the export flag and the project path.
    @Test func passesExportFlagAndSourceDirectory() async throws {
        let (fixture, generator) = try makeProject()
        _ = try await generator.generate(projectURL: fixture.root)
        let arguments = try fixture.read("cmake-args.txt")
            .split(separator: "\n").map(String.init)
        #expect(arguments == [
            "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
            fixture.root.path,
        ])
    }

    /// @brief cmake runs with variables from .aember/cmake-env.
    @Test func usesCMakeEnvFile() async throws {
        let (fixture, generator) = try makeProject()
        try fixture.write(".aember/cmake-env", "AEMBER_TEST_CMAKE=\"on\"\n")
        _ = try await generator.generate(projectURL: fixture.root)
        #expect(try fixture.read("cmake-env.txt") == "on")
    }

    /// @brief A named build directory is used, and an existing one is
    /// not reported as created.
    @Test func usesExistingNamedBuildDirectory() async throws {
        let (fixture, generator) = try makeProject(
            script: "printf '%s' '[]' > compile_commands.json"
        )
        try fixture.makeDirectory("cmake-build-debug")
        let output = OutputLines()
        _ = try await generator.generate(
            projectURL: fixture.root,
            buildDirectory: "cmake-build-debug",
            onOutput: output.append
        )
        #expect(fixture.exists("cmake-build-debug/compile_commands.json"))
        #expect(!fixture.exists("build"))
        #expect(!output.text.contains("Created build directory"))
    }

    /// @brief An existing .aember database is replaced.
    @Test func replacesExistingDatabase() async throws {
        let (fixture, generator) = try makeProject()
        try fixture.write(".aember/compile_commands.json", "old")
        _ = try await generator.generate(projectURL: fixture.root)
        #expect(try fixture.read(".aember/compile_commands.json")
            == Self.database)
    }

    /// @brief A failing cmake reports its stdout and stderr.
    @Test func configurationFailureReportsOutput() async throws {
        let (fixture, generator) = try makeProject(script: """
            echo "-- out line"
            echo "CMake Error: bad things" >&2
            exit 1
            """)
        do {
            _ = try await generator.generate(projectURL: fixture.root)
            Issue.record("Expected cmakeConfigurationFailed")
        } catch CMakeGeneratorError.cmakeConfigurationFailed(let output) {
            #expect(output.contains("-- out line"))
            #expect(output.contains("CMake Error: bad things"))
        }
        #expect(!fixture.exists(".aember/compile_commands.json"))
    }

    /// @brief cmake succeeding without a database is an error.
    @Test func missingDatabaseIsError() async throws {
        let (fixture, generator) = try makeProject(script: "exit 0")
        let error = await #expect(throws: CMakeGeneratorError.self) {
            _ = try await generator.generate(projectURL: fixture.root)
        }
        guard case .compilationDatabaseNotFound(let url)? = error else {
            Issue.record("Unexpected error: \(String(describing: error))")
            return
        }
        #expect(url == fixture.url("build/compile_commands.json"))
    }

    /// @brief A missing cmake executable fails configuration.
    @Test func missingExecutableFails() async throws {
        let fixture = try BuildSystemFixture()
        let generator = CMakeGenerator(
            executablePath: fixture.url("no-such-cmake").path
        )
        let error = await #expect(throws: CMakeGeneratorError.self) {
            _ = try await generator.generate(projectURL: fixture.root)
        }
        guard case .cmakeConfigurationFailed? = error else {
            Issue.record("Unexpected error: \(String(describing: error))")
            return
        }
    }

    /// @brief A stale cache from another source directory is removed and
    /// cmake is run again.
    @Test func recoversFromStaleCache() async throws {
        let (fixture, generator) = try makeProject(script: """
            if [ -f CMakeCache.txt ]; then
                echo "CMake Error: The current CMakeCache.txt directory" \
                    "/x/CMakeCache.txt is different than the directory" \
                    "/y where CMakeCache.txt was created." >&2
                exit 1
            fi
            printf '%s' '[]' > compile_commands.json
            """)
        try fixture.write("build/CMakeCache.txt", "stale")
        try fixture.write("build/CMakeFiles/cmake.check_cache", "stale")
        let output = OutputLines()
        _ = try await generator.generate(
            projectURL: fixture.root,
            onOutput: output.append
        )
        #expect(!fixture.exists("build/CMakeCache.txt"))
        #expect(!fixture.exists("build/CMakeFiles"))
        #expect(try fixture.read(".aember/compile_commands.json") == "[]")
        #expect(output.lines.contains(
            "Detected stale CMake cache, cleaning build directory…"
        ))
    }

    /// @brief The stale cache message is recognized when a read ends
    /// in the middle of it.
    @Test func recoversFromStaleCacheMessageCutAcrossReads() async throws {
        let (fixture, generator) = try makeProject(script: """
            if [ -f CMakeCache.txt ]; then
                printf 'CMake Error: The current CMakeCache.txt dir' >&2
                sleep 0.2
                printf 'ectory /x/CMakeCache.txt is different than' >&2
                echo ' the directory /y where CMakeCache.txt was created.' >&2
                exit 1
            fi
            printf '%s' '[]' > compile_commands.json
            """)
        try fixture.write("build/CMakeCache.txt", "stale")
        _ = try await generator.generate(projectURL: fixture.root)
        #expect(!fixture.exists("build/CMakeCache.txt"))
        #expect(try fixture.read(".aember/compile_commands.json") == "[]")
    }

    /// @brief Output reaches onOutput as whole lines, wherever reads end.
    /// @param body Shell commands that print the output
    /// @param expected The lines onOutput should receive
    @Test(arguments: [
        (#"printf 'first ha'; sleep 0.2; printf 'lf\nnext\n'"#,
         ["first half", "next"]),
        (#"printf 'caf\303'; sleep 0.2; printf '\251 done\n'"#,
         ["café done"]),
        (#"printf 'one\r'; sleep 0.2; printf '\ntwo\r\n'"#,
         ["one", "two"]),
        (#"printf 'no newline at the end'"#,
         ["no newline at the end"]),
    ])
    func deliversWholeLines(body: String, expected: [String]) async throws {
        let (fixture, generator) = try makeProject(script: """
            \(body)
            printf '%s' '[]' > compile_commands.json
            """)
        let output = OutputLines()
        _ = try await generator.generate(
            projectURL: fixture.root,
            onOutput: output.append
        )
        for line in expected {
            #expect(output.lines.contains(line))
        }
    }

    /// @brief Every error has a non-empty description.
    @Test(arguments: [
        CMakeGeneratorError.buildDirectoryCreationFailed(
            URL(fileURLWithPath: "/b")
        ),
        .cmakeConfigurationFailed("details"),
        .compilationDatabaseNotFound(URL(fileURLWithPath: "/c")),
    ])
    func errorDescriptions(error: CMakeGeneratorError) {
        #expect(error.errorDescription?.isEmpty == false)
    }
}
