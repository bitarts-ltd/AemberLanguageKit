/**
    @file NinjaGeneratorTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for NinjaGenerator.
    @details
    Runs the generator against a fake ninja shell script that prints
    canned `ninja -t compdb` output, so no real ninja is needed. Covers
    build directory discovery, arguments, environment, error handling,
    and output larger than a pipe buffer.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import CFamilyPack

@Suite("NinjaGenerator")
struct NinjaGeneratorTests {

    /// Canned compdb output printed by the fake ninja
    private static let database =
        #"[{"directory":"/x","command":"cc -c a.c","file":"a.c"}]"#

    /// @brief Create a fixture project with a fake ninja.
    /// @param script Body of the fake ninja script; by default it
    /// records its arguments and prints the canned database
    /// @return The fixture and a generator that runs the fake
    private func makeProject(
        script: String? = nil
    ) throws -> (BuildSystemFixture, NinjaGenerator) {
        let fixture = try BuildSystemFixture()
        let body = script ?? """
            printf '%s\\n' "$@" > "\(fixture.url("ninja-args.txt").path)"
            printf '%s' '\(Self.database)'
            """
        let ninja = try fixture.writeScript("tools/ninja", body)
        return (fixture, NinjaGenerator(executablePath: ninja.path))
    }

    /// @brief Read the arguments recorded by the default fake ninja.
    /// @param fixture The project fixture
    /// @return One argument per element
    private func recordedArguments(_ fixture: BuildSystemFixture) throws
        -> [String] {
        return try fixture.read("ninja-args.txt")
            .split(separator: "\n").map(String.init)
    }

    /// @brief The compdb output is written to .aember.
    @Test func writesDatabase() async throws {
        let (fixture, generator) = try makeProject()
        try fixture.write("build.ninja")
        let output = OutputLines()
        let result = try await generator.generate(
            projectURL: fixture.root,
            onOutput: output.append
        )
        #expect(result == fixture.url(".aember/compile_commands.json"))
        #expect(try fixture.read(".aember/compile_commands.json")
            == Self.database)
        #expect(output.lines.last == "Generated compilation database")
    }

    /// @brief build.ninja or rules.ninja is found in the root, build/
    /// or out/, as the detector finds it, and ninja is run with
    /// `-C <dir> -t compdb`.
    @Test(arguments: [
        ("build.ninja", ""),
        ("build/build.ninja", "build"),
        ("out/build.ninja", "out"),
        ("out/rules.ninja", "out"),
    ])
    func findsBuildDirectory(ninjaFile: String, directory: String) async throws {
        let (fixture, generator) = try makeProject()
        try fixture.write(ninjaFile)
        _ = try await generator.generate(projectURL: fixture.root)
        let expectedDirectory = directory.isEmpty
            ? fixture.root
            : fixture.url(directory)
        #expect(try recordedArguments(fixture) == [
            "-C", expectedDirectory.path, "-t", "compdb",
        ])
    }

    /// @brief An explicit build directory is used as given.
    @Test func usesExplicitBuildDirectory() async throws {
        let (fixture, generator) = try makeProject()
        try fixture.makeDirectory("custom")
        _ = try await generator.generate(
            projectURL: fixture.root,
            buildDirectory: "custom"
        )
        #expect(try recordedArguments(fixture)[1] == fixture.url("custom").path)
    }

    /// @brief A missing explicit build directory is an error.
    @Test func missingExplicitBuildDirectory() async throws {
        let (fixture, generator) = try makeProject()
        let error = await #expect(throws: NinjaGeneratorError.self) {
            _ = try await generator.generate(
                projectURL: fixture.root,
                buildDirectory: "nope"
            )
        }
        guard case .buildDirectoryNotFound(let url)? = error else {
            Issue.record("Unexpected error: \(String(describing: error))")
            return
        }
        #expect(url == fixture.url("nope"))
    }

    /// @brief No build.ninja anywhere is an error naming the project.
    @Test func noBuildNinjaFound() async throws {
        let (fixture, generator) = try makeProject()
        try fixture.write(".ninja/build.ninja")
        let error = await #expect(throws: NinjaGeneratorError.self) {
            _ = try await generator.generate(projectURL: fixture.root)
        }
        guard case .buildDirectoryNotFound(let url)? = error else {
            Issue.record("Unexpected error: \(String(describing: error))")
            return
        }
        #expect(url == fixture.root)
    }

    /// @brief ninja runs with variables from .aember/ninja-env.
    @Test func usesNinjaEnvFile() async throws {
        let (fixture, generator) = try makeProject(
            script: #"printf '%s' "$AEMBER_TEST_NINJA""#
        )
        try fixture.write("build.ninja")
        try fixture.write(".aember/ninja-env", "AEMBER_TEST_NINJA=[42]\n")
        _ = try await generator.generate(projectURL: fixture.root)
        #expect(try fixture.read(".aember/compile_commands.json") == "[42]")
    }

    /// @brief Stderr is forwarded to the output callback.
    @Test func forwardsStderr() async throws {
        let (fixture, generator) = try makeProject(script: """
            echo "ninja: warning: something" >&2
            printf '[]'
            """)
        try fixture.write("build.ninja")
        let output = OutputLines()
        _ = try await generator.generate(
            projectURL: fixture.root,
            onOutput: output.append
        )
        #expect(output.text.contains("ninja: warning: something"))
    }

    /// @brief A failing ninja reports its stderr.
    @Test func commandFailureReportsStderr() async throws {
        let (fixture, generator) = try makeProject(script: """
            echo "ninja: error: loading 'build.ninja'" >&2
            exit 1
            """)
        try fixture.write("build.ninja")
        let error = await #expect(throws: NinjaGeneratorError.self) {
            _ = try await generator.generate(projectURL: fixture.root)
        }
        guard case .ninjaCommandFailed(let message)? = error else {
            Issue.record("Unexpected error: \(String(describing: error))")
            return
        }
        #expect(message.contains("ninja: error: loading"))
    }

    /// @brief Empty compdb output means no compilation rules.
    @Test func emptyOutputIsError() async throws {
        let (fixture, generator) = try makeProject(script: "exit 0")
        try fixture.write("build.ninja")
        let error = await #expect(throws: CompilationDatabaseError.self) {
            _ = try await generator.generate(projectURL: fixture.root)
        }
        guard case .noCompilationCommands? = error else {
            Issue.record("Unexpected error: \(String(describing: error))")
            return
        }
    }

    /// @brief Output far larger than a pipe buffer is read completely.
    @Test(.timeLimit(.minutes(1)))
    func readsLargeOutput() async throws {
        let (fixture, generator) = try makeProject(script: """
            echo "large stderr line" >&2
            printf '['
            i=0
            while [ $i -lt 3000 ]; do
                printf '{"directory":"/x","command":"cc -c f%04d.c",' $i
                printf '"file":"f%04d.c"},\\n' $i
                i=$((i + 1))
            done
            printf '{"directory":"/x","command":"cc","file":"end.c"}]'
            """)
        try fixture.write("build.ninja")
        _ = try await generator.generate(projectURL: fixture.root)
        let data = try Data(
            contentsOf: fixture.url(".aember/compile_commands.json")
        )
        #expect(data.count > 150_000)
        let commands = try JSONDecoder().decode([CompileCommand].self, from: data)
        #expect(commands.count == 3001)
        #expect(commands.last?.file == "end.c")
    }

    /// @brief A missing ninja executable is reported as a failure.
    @Test func missingExecutableFails() async throws {
        let fixture = try BuildSystemFixture()
        try fixture.write("build.ninja")
        let generator = NinjaGenerator(
            executablePath: fixture.url("no-such-ninja").path
        )
        let error = await #expect(throws: NinjaGeneratorError.self) {
            _ = try await generator.generate(projectURL: fixture.root)
        }
        guard case .ninjaCommandFailed? = error else {
            Issue.record("Unexpected error: \(String(describing: error))")
            return
        }
    }

    /// @brief Every error has a non-empty description.
    @Test(arguments: [
        NinjaGeneratorError.buildDirectoryNotFound(URL(fileURLWithPath: "/b")),
        .ninjaCommandFailed("details"),
    ])
    func errorDescriptions(error: NinjaGeneratorError) {
        #expect(error.errorDescription?.isEmpty == false)
    }
}
