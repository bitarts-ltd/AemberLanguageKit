/**
    @file NodePackageChecksTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Tests for Check for Updates with npm, pnpm and Yarn.
    @details
    The registry's versions matched with each direct dependency's
    range, npm's, pnpm's and Yarn's audit reports from saved output,
    and, with AEMBER_LIVE_PACKAGE_CHECKS set, the real npm against its
    registry.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import TypeScriptPack

/// The Fixtures folder beside this file
private let fixtures = PackageFixtures()

/// @brief Runs tools as processes, for the live test
private final class ProcessRunner: PackageToolRunner, @unchecked Sendable {
    func find(_ tool: String) -> URL? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func run(_ tool: String, arguments: [String], in folder: URL) throws -> PackageToolResult {
        guard let executable = find(tool) else { throw PackageError.toolMissing(tool) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return PackageToolResult(status: process.terminationStatus, output: data, errorText: String(decoding: errorData, as: UTF8.self))
    }
}

@Suite("Node package checks", .serialized, .timeLimit(.minutes(2)))
struct NodePackageChecksTests {

    // MARK: - npm

    static func npmGraph() throws -> PackageGraph {
        NPMBackend.graph(
            manifest: try fixtures.object("npm-package.json"),
            lock: try fixtures.object("npm-package-lock-v3.json"),
            folder: URL(fileURLWithPath: "/work")
        )
    }

    @Test func npmAuditReport() throws {
        let graph = try Self.npmGraph()
        let advisories = NPMBackend.parseAudit(try fixtures.object("npm-audit.json"), graph: graph)
        // One advisory, on both copies of brace-expansion; the package
        // vulnerable only through it has none of its own
        #expect(advisories.map(\.packageID) == [
            "node_modules/brace-expansion",
            "node_modules/@typescript-eslint/typescript-estree/node_modules/brace-expansion",
        ])
        #expect(advisories.first?.identifier == "GHSA-v6h2-p8h4-qcjw")
        #expect(advisories.first?.severity == "low")
        #expect(advisories.first?.version == "1.1.12")
    }

    @Test func npmCheckedPackagesSkipFolders() throws {
        let names = NPMBackend.checkedPackages(in: try Self.npmGraph()).map(\.name)
        #expect(names.contains("react"))
        #expect(!names.contains("local-kit"))
    }

    @Test func npmRegistriesFromNpmrc() {
        var configuration = NPMRegistryConfiguration()
        configuration.read("""
            # a comment
            registry=https://npm.example.com/
            @corp:registry="https://corp.example.com/npm"
            //npm.example.com/:_authToken=${TOKEN}
            """)
        #expect(configuration.registry.absoluteString == "https://npm.example.com")
        #expect(configuration.registry(for: "@corp/ui").absoluteString == "https://corp.example.com/npm")
        #expect(configuration.registry(for: "@other/ui").absoluteString == "https://npm.example.com")
        #expect(configuration.registry(for: "react").absoluteString == "https://npm.example.com")
    }

    @Test func npmCheckAsksTheRegistry() async throws {
        let service = StubHTTPService()
        service.on("/react") { _ in .json(200, ["dist-tags": ["latest": "19.3.0"], "versions": ["19.2.4": [:], "19.3.0": [:], "20.0.0-rc.1": [:]]]) }
        service.on("/react-dom") { _ in .json(200, ["dist-tags": ["latest": "20.1.0"], "versions": ["19.2.4": [:], "19.2.5": [:], "20.1.0": [:]]]) }
        service.on("/clsx") { _ in .json(200, ["dist-tags": ["latest": "2.1.1"], "versions": ["2.1.1": [:]]]) }
        service.on("/@typescript-eslint/typescript-estree") { _ in .json(200, ["dist-tags": ["latest": "8.54.0"], "versions": ["8.54.0": [:]]]) }
        let runner = FakePackageToolRunner()
        runner.answer("npm audit --json", with: try fixtures.data("npm-audit.json"), status: 1)
        var registries = NPMRegistryConfiguration()
        registries.registry = URL(string: "https://npm.test")!
        let result = await NPMBackend.check(
            graph: try Self.npmGraph(),
            registries: registries,
            http: PackageHTTP(session: service.session),
            runner: runner,
            folder: URL(fileURLWithPath: "/work")
        )
        let byID = Dictionary(uniqueKeysWithValues: result.updates.map { ($0.packageID, $0) })
        #expect(byID["node_modules/react"] == PackageUpdate(packageID: "node_modules/react", current: "19.2.4", compatible: "19.3.0", latest: "19.3.0"))
        #expect(byID["node_modules/react-dom"] == PackageUpdate(packageID: "node_modules/react-dom", current: "19.2.4", compatible: "19.2.5", latest: "20.1.0"))
        #expect(byID["node_modules/clsx"] == nil)
        // typescript isn't served: a problem names it
        #expect(result.problems.count == 1)
        #expect(result.problems.first?.contains("typescript") == true)
        #expect(result.advisories.count == 2)
        #expect(service.requests(to: "/local-kit").isEmpty)

        // An audit npm refuses is a problem
        runner.answer("npm audit --json", with: Data("{\"error\": {\"code\": \"ENOLOCK\", \"summary\": \"This command requires an existing lockfile.\"}}".utf8), status: 1)
        let audit = NPMBackend.audit(graph: try Self.npmGraph(), runner: runner, folder: URL(fileURLWithPath: "/work"))
        #expect(audit.advisories.isEmpty)
        #expect(audit.problem == "This command requires an existing lockfile.")
    }


    // MARK: - Live

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AEMBER_LIVE_PACKAGE_CHECKS"] != nil))
    func liveCheckReachesTheRegistry() async throws {
        let runner = ProcessRunner()
        let http = PackageHTTP()
        let temp = try PackageTempFolder()
        defer { temp.remove() }

        if runner.find("npm") != nil {
            let manifest = try temp.write("web/package.json", "{\"name\": \"w\", \"version\": \"1.0.0\", \"dependencies\": {\"lodash\": \"4.17.15\", \"minimist\": \"^1.2.0\"}}")
            let folder = manifest.deletingLastPathComponent()
            _ = try runner.run("npm", arguments: ["install", "--package-lock-only", "--silent"], in: folder)
            let backend = NPMBackend(manifestURL: manifest, runner: runner)
            let result = await backend.check(graph: try backend.readGraph(), http: http)
            let lodash = try #require(result.updates.first { $0.packageID == "node_modules/lodash" })
            #expect(lodash.compatible == nil)
            #expect(lodash.isOutsideRule)
            #expect(result.advisories.contains { $0.packageID == "node_modules/lodash" && $0.identifier.hasPrefix("GHSA-") })
            #expect(result.problems.isEmpty)
        }
    }
}
