/**
    @file SwiftBuildSystemTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for the Swift package and Xcode build systems.
    @details
    Their commands: swift build and test with a filter; xcodebuild with
    the scheme named like the project (listed by the context), a result
    bundle and -only-testing, build.json's scheme, configuration and
    destination, and no scheme at all. Xcode's sameness and build files
    inside its bundles. Their compilation databases with fake tools
    from the context: xcode-build-server configured for an Xcode
    project, xcodebuild when it fails, and a Swift package needing
    none unless an Xcode project is beside it. Moved from Aember's
    BuildCommandResolverTests, BuildSystemTests and
    CompilationDatabaseManagerTests with the build systems.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import SwiftPack

/// @brief A context with fake tools and Xcode schemes
private struct FakeTools: BuildSystemContext, XcodeSchemeLister {
    var tools: [String: String] = [:]
    var schemeList: [String] = []

    func toolPath(_ name: String) -> String? {
        tools[name]
    }

    func schemes(in root: URL, system: XcodeBuildSystem) -> [String] {
        schemeList
    }
}

@Suite("Swift build systems")
struct SwiftBuildSystemTests {

    private let output = URL(fileURLWithPath: "/tmp/out")

    private func command(_ action: BuildAction, _ system: any BuildSystem, config: BuildProjectConfig? = nil, filter: String? = nil, schemes: [String] = []) throws -> BuildCommand {
        try system.command(for: action, in: URL(fileURLWithPath: "/nonexistent"), config: config, filter: filter, outputDirectory: output, context: FakeTools(schemeList: schemes))
    }

    private func steps(_ command: BuildCommand) -> [[String]] {
        command.steps.map { [$0.executable] + $0.arguments }
    }

    // MARK: - Commands

    /// @brief SwiftPM's commands and filters.
    @Test func swiftPM() throws {
        #expect(steps(try command(.build, SwiftPMBuildSystem())) == [["swift", "build"]])
        #expect(steps(try command(.test, SwiftPMBuildSystem(), filter: "M.S/t")) == [["swift", "test", "--filter", "M.S/t"]])
    }

    /// @brief xcodebuild with the scheme named like the project, a
    /// result bundle and -only-testing; build.json's settings; no scheme.
    @Test func xcode() throws {
        let system = XcodeBuildSystem(workspace: nil, project: "App.xcodeproj", scheme: nil)
        let test = try command(.test, system, filter: "AppTests/Suite", schemes: ["Other", "App"])
        #expect(steps(test) == [[
            "xcodebuild", "-project", "App.xcodeproj", "-scheme", "App",
            "test", "-resultBundlePath", "/tmp/out/Result.xcresult",
            "-only-testing:AppTests/Suite"
        ]])
        #expect(test.report?.url.lastPathComponent == "Result.xcresult")
        #expect(test.report?.format == "xcresult")

        let config = BuildProjectConfig(scheme: "Mine", destination: "platform=macOS", configuration: "Release")
        let build = try command(.build, XcodeBuildSystem(workspace: "W.xcworkspace", project: "App.xcodeproj", scheme: nil), config: config, schemes: ["App"])
        #expect(steps(build)[0].prefix(10) == [
            "xcodebuild", "-workspace", "W.xcworkspace", "-scheme", "Mine",
            "-configuration", "Release", "-destination", "platform=macOS", "build"
        ])

        #expect(throws: BuildCommandError.self) {
            try command(.build, system, schemes: [])
        }
    }

    /// @brief Without a lister of its own, the context's xcodebuild lists
    /// the schemes.
    @Test func xcodebuildListsSchemes() throws {
        let fixture = try BuildSystemFixture()
        let list = try fixture.writeScript("tools/xcodebuild", #"echo '{"project":{"name":"App","schemes":["Tool","App"]}}'"#)
        let system = XcodeBuildSystem(workspace: nil, project: "App.xcodeproj", scheme: nil)
        #expect(XcodeBuildSystem.schemes(in: fixture.root, system: system, context: Tools(paths: ["xcodebuild": list.path])) == ["Tool", "App"])
    }

    // MARK: - Sameness and Build Files

    /// @brief Sameness compares the bundles.
    @Test func sameness() {
        #expect(XcodeBuildSystem(workspace: "W", project: nil, scheme: nil).isSame(as: XcodeBuildSystem(workspace: "W", project: nil, scheme: nil)))
        #expect(!XcodeBuildSystem(workspace: "W", project: nil, scheme: nil).isSame(as: XcodeBuildSystem(workspace: nil, project: "W", scheme: nil)))
    }

    /// @brief Xcode's build files are inside its bundles, the project's
    /// first, since build settings live there.
    @Test func buildFiles() throws {
        #expect(XcodeBuildSystem(workspace: nil, project: nil, scheme: nil).buildFiles.isEmpty)
        #expect(XcodeBuildSystem(workspace: "W.xcworkspace", project: "A.xcodeproj", scheme: nil).buildFiles == ["A.xcodeproj/project.pbxproj", "W.xcworkspace/contents.xcworkspacedata"])
        let fixture = try BuildSystemFixture()
        try fixture.write("App.xcodeproj/project.pbxproj")
        try fixture.write("App.xcworkspace/contents.xcworkspacedata")
        #expect(XcodeBuildSystem(workspace: "App.xcworkspace", project: "App.xcodeproj", scheme: nil).buildFileURL(in: fixture.root) == fixture.url("App.xcodeproj/project.pbxproj"))
        #expect(XcodeBuildSystem(workspace: "App.xcworkspace", project: nil, scheme: nil).buildFileURL(in: fixture.root) == fixture.url("App.xcworkspace/contents.xcworkspacedata"))
    }

    // MARK: - Compilation Databases

    /// @brief A context with fake tools only
    private struct Tools: BuildSystemContext {
        var paths: [String: String]

        func toolPath(_ name: String) -> String? {
            paths[name]
        }
    }

    /// @brief Fake xcode-build-server (writing buildServer.json, or
    /// failing) and an xcodebuild listing the App scheme.
    private func buildServerTools(in fixture: BuildSystemFixture, fails: Bool = false) throws -> [String: String] {
        let tool = try fixture.writeScript("tools/xcode-build-server", fails ? "echo 'no scheme' >&2; exit 1" : "echo '{}' > buildServer.json")
        let list = try fixture.writeScript("tools/xcodebuild-list", #"echo '{"project":{"name":"App","schemes":["App"]}}'"#)
        return ["xcode-build-server": tool.path, "xcodebuild": list.path]
    }

    /// @brief An Xcode project configures xcode-build-server.
    @Test func xcodeUsesBuildServer() async throws {
        let fixture = try BuildSystemFixture()
        try fixture.makeDirectory("App.xcodeproj")
        let system = try #require(XcodeBuildSystem.detect(in: fixture.root))
        let output = try await system.compilationDatabase(for: fixture.root, context: Tools(paths: buildServerTools(in: fixture)), onOutput: nil)
        #expect(output == .buildServer(fixture.url("buildServer.json")))
    }

    /// @brief When xcode-build-server fails, xcodebuild is used.
    @Test func xcodeFallsBackToXcodebuild() async throws {
        let fixture = try BuildSystemFixture()
        try fixture.makeDirectory("App.xcodeproj")
        var tools = try buildServerTools(in: fixture, fails: true)
        tools["xcodebuild"] = try fixture.writeScript("tools/xcodebuild", "echo ran >> \"\(fixture.url("xcodebuild-runs.txt").path)\"; exit 65").path
        let system = try #require(XcodeBuildSystem.detect(in: fixture.root))
        let lines = OutputLines()
        await #expect(throws: (any Error).self) {
            _ = try await system.compilationDatabase(for: fixture.root, context: Tools(paths: tools), onOutput: lines.append)
        }
        #expect(lines.lines.contains { $0.hasPrefix("xcode-build-server failed") })
        #expect(fixture.exists("xcodebuild-runs.txt"))
        #expect(!fixture.exists("buildServer.json"))
    }

    /// @brief A Swift package needs no database; with an Xcode project
    /// beside Package.swift, xcode-build-server is configured.
    @Test func swiftPackage() async throws {
        let fixture = try BuildSystemFixture()
        try fixture.write("Package.swift", "// swift-tools-version:5.9\n")
        let system = SwiftPMBuildSystem()
        let without = Tools(paths: ["xcode-build-server": fixture.url("tools/none").path])
        #expect(try await system.compilationDatabase(for: fixture.root, context: without, onOutput: nil) == .native(fixture.url("Package.swift")))
        try fixture.makeDirectory("App.xcodeproj")
        #expect(try await system.compilationDatabase(for: fixture.root, context: Tools(paths: buildServerTools(in: fixture)), onOutput: nil) == .buildServer(fixture.url("buildServer.json")))
    }
}
