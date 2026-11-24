/**
    @file CFamilyCommandTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Tests for CMake's, Ninja's and Make's commands, sameness and build
    files.
    @details
    Moved from Aember's BuildCommandResolverTests and BuildSystemTests
    with the build systems.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import CFamilyPack

/// @brief A context with nothing in it
private struct NoContext: BuildSystemContext {}

@Suite("C Family commands")
struct CFamilyCommandTests {

    private let output = URL(fileURLWithPath: "/tmp/out")

    private func command(_ action: BuildAction, _ system: any BuildSystem, root: URL = URL(fileURLWithPath: "/nonexistent"), filter: String? = nil) throws -> BuildCommand {
        try system.command(for: action, in: root, config: nil, filter: filter, outputDirectory: output, context: NoContext())
    }

    private func steps(_ command: BuildCommand) -> [[String]] {
        command.steps.map { [$0.executable] + $0.arguments }
    }

    /// @brief CMake configures a new build directory, then builds; tests
    /// run with ctest writing JUnit.
    @Test func cmake() throws {
        let fixture = try BuildSystemFixture()
        let fresh = try command(.build, CMakeBuildSystem(buildDirectory: nil), root: fixture.root)
        #expect(steps(fresh) == [
            ["cmake", "-S", ".", "-B", "build"], ["cmake", "--build", "build"]
        ])
        try fixture.write("out/CMakeCache.txt")
        let configured = try command(
            .build, CMakeBuildSystem(buildDirectory: "out"), root: fixture.root
        )
        #expect(steps(configured) == [["cmake", "--build", "out"]])
        let test = try command(
            .test, CMakeBuildSystem(buildDirectory: "out"), root: fixture.root, filter: "math"
        )
        #expect(steps(test) == [[
            "ctest", "--test-dir", "out", "--output-on-failure",
            "--output-junit", "/tmp/out/junit.xml", "-R", "math"
        ]])
    }

    /// @brief Ninja builds with ninja; tests with ctest when CMake made
    /// the directory, else ninja's test target.
    @Test func ninja() throws {
        let fixture = try BuildSystemFixture()
        #expect(steps(try command(.build, NinjaBuildSystem(buildDirectory: nil), root: fixture.root))
            == [["ninja", "-C", "."]])
        #expect(steps(try command(.test, NinjaBuildSystem(buildDirectory: "b"), root: fixture.root))
            == [["ninja", "-C", "b", "test"]])
        try fixture.write("b/CTestTestfile.cmake")
        #expect(try command(.test, NinjaBuildSystem(buildDirectory: "b"), root: fixture.root)
            .steps[0].executable == "ctest")
    }


    /// @brief make builds and tests with make test, and takes no filter.
    @Test func make() throws {
        #expect(steps(try command(.build, MakeBuildSystem())) == [["make"]])
        #expect(steps(try command(.test, MakeBuildSystem())) == [["make", "test"]])
        #expect(try command(.build, MakeBuildSystem()).environmentIdentifier == "make")
        #expect(throws: BuildCommandError.self) {
            try command(.test, MakeBuildSystem(), filter: "x")
        }
    }

    /// @brief Sameness compares the kind and the settings.
    @Test func samenessComparesKindAndSettings() {
        #expect(CMakeBuildSystem(buildDirectory: "build").isSame(as: CMakeBuildSystem(buildDirectory: "build")))
        #expect(!CMakeBuildSystem(buildDirectory: "build").isSame(as: CMakeBuildSystem(buildDirectory: nil)))
        #expect(!NinjaBuildSystem(buildDirectory: "build").isSame(as: CMakeBuildSystem(buildDirectory: "build")))
        #expect(!MakeBuildSystem().isSame(as: nil))
    }

    /// @brief Ninja's build files are in its build directory; the first
    /// that exists is the build file.
    @Test func buildFiles() throws {
        #expect(NinjaBuildSystem(buildDirectory: nil).buildFiles == ["build.ninja", "rules.ninja"])
        #expect(NinjaBuildSystem(buildDirectory: "out").buildFiles == ["out/build.ninja", "out/rules.ninja"])
        #expect(MakeBuildSystem().buildFiles == ["Makefile", "makefile", "GNUmakefile"])
        let fixture = try BuildSystemFixture()
        try fixture.write("out/rules.ninja")
        #expect(NinjaBuildSystem(buildDirectory: "out").buildFileURL(in: fixture.root) == fixture.url("out/rules.ninja"))
        #expect(NinjaBuildSystem(buildDirectory: nil).buildFileURL(in: fixture.root) == nil)
    }
}
