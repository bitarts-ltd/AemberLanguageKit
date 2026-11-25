/**
    @file XcodeBuildServerManagerTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for configuring xcode-build-server.
    @details
    Runs XcodeBuildServerManager against fake xcode-build-server and
    xcodebuild shell scripts in a fixture project: locating the tool,
    the arguments passed for workspaces, projects, and schemes,
    scheme detection from canned `xcodebuild -list -json` output, and the
    errors for a missing tool, missing project, missing scheme,
    failing config, a config that writes no buildServer.json, and a
    failing config with more output than a pipe buffer holds.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import SwiftPack

@Suite("XcodeBuildServerManager")
struct XcodeBuildServerManagerTests {

    /// Canned `xcodebuild -list -json` output for the workspace; the
    /// scheme named like it is not the first
    private static let listOutput = """
        {"workspace": {"name": "App", "schemes": ["AppTests", "App"]}}
        """

    /// @brief Creates a fixture with fake tools.
    /// @param config Shell body of the fake xcode-build-server; by
    /// default it records its arguments and writes buildServer.json
    /// @param list Output of the fake xcodebuild -list
    /// @return The fixture and a manager using the fakes
    private func makeFixture(
        config: String? = nil,
        list: String = listOutput
    ) throws -> (BuildSystemFixture, XcodeBuildServerManager) {
        let fixture = try BuildSystemFixture()
        let argsFile = fixture.url("args.txt").path
        let body = config ?? """
            printf '%s\\n' "$@" > "\(argsFile)"
            echo '{"name":"xcode build server"}' > buildServer.json
            """
        let tool = try fixture.writeScript("tools/xcode-build-server", body)
        let listFile = try fixture.write("list.txt", list)
        let xcodebuildArgs = fixture.url("xcodebuild-args.txt").path
        let xcodebuild = try fixture.writeScript(
            "tools/xcodebuild",
            """
            printf '%s\\n' "$@" > "\(xcodebuildArgs)"
            cat "\(listFile.path)"
            """
        )
        let manager = XcodeBuildServerManager(
            executablePath: tool.path,
            xcodebuildPath: xcodebuild.path
        )
        return (fixture, manager)
    }

    /// @brief Lines a fake tool was called with.
    private func arguments(_ fixture: BuildSystemFixture, _ file: String)
        throws -> [String] {
        return try fixture.read(file)
            .split(separator: "\n")
            .map(String.init)
    }

    // MARK: - Locating

    /// @brief An explicit path is used only if it is executable.
    @Test func findExecutable() throws {
        let (fixture, manager) = try makeFixture()
        #expect(manager.findExecutable()
            == fixture.url("tools/xcode-build-server"))

        let plain = try fixture.write("tools/not-executable", "")
        #expect(XcodeBuildServerManager(executablePath: plain.path)
            .findExecutable() == nil)
        #expect(XcodeBuildServerManager(
            executablePath: fixture.url("missing").path
        ).findExecutable() == nil)
    }

    /// @brief Without the tool, configure reports it is not installed.
    @Test func notInstalled() async throws {
        let fixture = try BuildSystemFixture()
        try fixture.makeDirectory("App.xcodeproj")
        let manager = XcodeBuildServerManager(
            executablePath: fixture.url("missing").path
        )
        await #expect(throws: XcodeBuildServerError.self) {
            _ = try await manager.configure(projectURL: fixture.root)
        }
    }

    // MARK: - Configuring

    /// @brief A workspace is preferred over a project, and the scheme
    /// named like it comes from xcodebuild -list -json.
    @Test func workspaceAndDetectedScheme() async throws {
        let (fixture, manager) = try makeFixture()
        try fixture.makeDirectory("App.xcodeproj")
        try fixture.makeDirectory("App.xcworkspace")
        let output = OutputLines()

        let result = try await manager.configure(
            projectURL: fixture.root,
            onOutput: output.append
        )

        #expect(result == fixture.url("buildServer.json"))
        #expect(try arguments(fixture, "args.txt") == [
            "config", "-scheme", "App",
            "-workspace", fixture.url("App.xcworkspace").path
        ])
        #expect(try arguments(fixture, "xcodebuild-args.txt")
            == ["-list", "-json", "-workspace", "App.xcworkspace"])
        #expect(output.lines.contains("Detected scheme: App"))
        #expect(output.lines.last?.contains("configured successfully") == true)
    }

    /// @brief A given project and scheme are passed straight through.
    @Test func explicitProjectAndScheme() async throws {
        let (fixture, manager) = try makeFixture()
        try fixture.makeDirectory("Other.xcodeproj")

        _ = try await manager.configure(
            projectURL: fixture.root,
            project: "Other.xcodeproj",
            scheme: "Release Scheme"
        )

        #expect(try arguments(fixture, "args.txt") == [
            "config", "-scheme", "Release Scheme",
            "-project", fixture.url("Other.xcodeproj").path
        ])
        #expect(!fixture.exists("xcodebuild-args.txt"))
    }

    /// @brief A folder without an Xcode project is an error.
    @Test func noProject() async throws {
        let (fixture, manager) = try makeFixture()
        let error = await #expect(throws: XcodeBuildServerError.self) {
            _ = try await manager.configure(projectURL: fixture.root)
        }
        guard case .noProjectOrWorkspace = error else {
            Issue.record("Unexpected error \(String(describing: error))")
            return
        }
    }

    /// @brief A project without schemes is an error.
    @Test func noScheme() async throws {
        let (fixture, manager) = try makeFixture(
            list: #"{"project": {"name": "App", "targets": ["App"]}}"#
        )
        try fixture.makeDirectory("App.xcodeproj")
        let error = await #expect(throws: XcodeBuildServerError.self) {
            _ = try await manager.configure(projectURL: fixture.root)
        }
        guard case .noSchemeAvailable = error else {
            Issue.record("Unexpected error \(String(describing: error))")
            return
        }
    }

    /// @brief A failing config reports stderr, or stdout if stderr is
    /// empty.
    @Test(arguments: [
        ("echo 'bad scheme' >&2; echo ignored; exit 3", "bad scheme\n"),
        ("echo 'only stdout'; exit 1", "only stdout\n")
    ])
    func configFails(body: String, message: String) async throws {
        let (fixture, manager) = try makeFixture(config: body)
        try fixture.makeDirectory("App.xcodeproj")
        let error = await #expect(throws: XcodeBuildServerError.self) {
            _ = try await manager.configure(
                projectURL: fixture.root,
                scheme: "App"
            )
        }
        guard case .configFailed(let output) = error else {
            Issue.record("Unexpected error \(String(describing: error))")
            return
        }
        #expect(output == message)
        #expect(error?.errorDescription?.contains(message) == true)
    }

    /// @brief A config that succeeds without writing buildServer.json
    /// is an error.
    @Test func configWritesNothing() async throws {
        let (fixture, manager) = try makeFixture(config: "exit 0")
        try fixture.makeDirectory("App.xcodeproj")
        let error = await #expect(throws: XcodeBuildServerError.self) {
            _ = try await manager.configure(
                projectURL: fixture.root,
                scheme: "App"
            )
        }
        guard case .configFailed = error else {
            Issue.record("Unexpected error \(String(describing: error))")
            return
        }
    }

    /// @brief A tool that writes more than a pipe buffer before
    /// exiting does not hang the configuration.
    @Test(.timeLimit(.minutes(1)))
    func largeOutputDoesNotHang() async throws {
        let (fixture, manager) = try makeFixture(config: """
            i=0
            while [ $i -lt 3000 ]; do
                echo "error line $i: something went quite wrong here" >&2
                echo "output line $i: some progress information here"
                i=$((i + 1))
            done
            exit 2
            """)
        try fixture.makeDirectory("App.xcodeproj")
        let error = await #expect(throws: XcodeBuildServerError.self) {
            _ = try await manager.configure(
                projectURL: fixture.root,
                scheme: "App"
            )
        }
        guard case .configFailed(let output) = error else {
            Issue.record("Unexpected error \(String(describing: error))")
            return
        }
        #expect(output.hasSuffix("error line 2999: something went quite "
            + "wrong here\n"))
    }
}
