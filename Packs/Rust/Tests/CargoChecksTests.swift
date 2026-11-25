/**
    @file CargoChecksTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for Check for Updates with Cargo.
    @details
    cargo update's dry run and cargo audit's report from saved output,
    the check running the tools through a fake runner, and, with
    AEMBER_LIVE_PACKAGE_CHECKS set, the real cargo against crates.io.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import RustPack

/// The Fixtures folder beside this file
private let fixtures = PackageFixtures()

/// @brief Runs tools as processes, for the live test
private final class ProcessRunner: PackageToolRunner, @unchecked Sendable {
    func find(_ tool: String) -> URL? {
        ["/opt/homebrew/bin", "/usr/local/bin", NSString(string: "~/.cargo/bin").expandingTildeInPath, "/usr/bin"].map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func run(_ tool: String, arguments: [String], in folder: URL) throws -> PackageToolResult {
        guard let executable = find(tool) else { throw PackageError.toolMissing(tool) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
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

@Suite("Cargo checks", .serialized, .timeLimit(.minutes(2)))
struct CargoChecksTests {

    // MARK: - Cargo

    static let cargoGraph = PackageGraph(
        rootName: "c4",
        dependencies: [
            PackageDependency(name: "anyhow", rule: .requirement("=1.0.80"), resolvedID: "anyhow 1.0.80"),
            PackageDependency(name: "rand", rule: .requirement("0.7"), resolvedID: "rand 0.7.0"),
        ],
        packages: [
            ResolvedPackage(id: "anyhow 1.0.80", name: "anyhow", version: "1.0.80"),
            ResolvedPackage(id: "rand 0.7.0", name: "rand", version: "0.7.0"),
            ResolvedPackage(id: "time 0.1.45", name: "time", version: "0.1.45"),
        ]
    )

    @Test func cargoDryRunAndAudit() throws {
        let updates = CargoBackend.parseDryRun(try fixtures.text("cargo-update-dry-run.txt"), graph: Self.cargoGraph)
        #expect(updates == [
            PackageUpdate(packageID: "anyhow 1.0.80", current: "1.0.80", compatible: nil, latest: "1.0.104"),
            PackageUpdate(packageID: "rand 0.7.0", current: "0.7.0", compatible: "0.7.3", latest: "0.10.4"),
        ])
        // An update without "available" is the newest there is
        let plain = CargoBackend.parseDryRun("    Updating rand v0.7.0 -> v0.7.3\n", graph: Self.cargoGraph)
        #expect(plain.first?.latest == "0.7.3")
        #expect(plain.first?.isOutsideRule == false)

        let advisories = CargoBackend.parseAudit(try fixtures.object("cargo-audit.json"), graph: Self.cargoGraph)
        #expect(advisories.count == 1)
        #expect(advisories.first?.packageID == "time 0.1.45")
        #expect(advisories.first?.identifier == "RUSTSEC-2020-0071")
        #expect(advisories.first?.url?.absoluteString == "https://github.com/time-rs/time/issues/293")
    }

    @Test func cargoCheckRunsTheTools() throws {
        let runner = FakePackageToolRunner()
        let folder = URL(fileURLWithPath: "/work")
        runner.answer("cargo update --dry-run --verbose", with: Data(), error: try fixtures.text("cargo-update-dry-run.txt"))
        var result = CargoBackend.check(graph: Self.cargoGraph, runner: runner, folder: folder)
        #expect(result.updates.count == 2)
        #expect(result.advisories.isEmpty)
        // Without cargo-audit, it says how to get it
        #expect(result.problems.count == 1)
        #expect(result.problems.first?.contains("cargo install cargo-audit") == true)

        runner.installed.insert("cargo-audit")
        runner.answer("cargo audit --json", with: try fixtures.data("cargo-audit.json"), status: 1)
        result = CargoBackend.check(graph: Self.cargoGraph, runner: runner, folder: folder)
        #expect(result.problems.isEmpty)
        #expect(result.advisories.map(\.identifier) == ["RUSTSEC-2020-0071"])

        // A failed dry run is a problem, not an error
        runner.answer("cargo update --dry-run --verbose", with: Data(), status: 101, error: "error: failed to get `rand` as a dependency\n")
        result = CargoBackend.check(graph: Self.cargoGraph, runner: runner, folder: folder)
        #expect(result.updates.isEmpty)
        #expect(result.problems.first == "error: failed to get `rand` as a dependency")
    }


    // MARK: - Live

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AEMBER_LIVE_PACKAGE_CHECKS"] != nil))
    func liveCheckReachesCratesIO() async throws {
        let runner = ProcessRunner()
        let http = PackageHTTP()
        let temp = try PackageTempFolder()
        defer { temp.remove() }

        if runner.find("cargo") != nil {
            let manifest = try temp.write("rust/Cargo.toml", "[package]\nname = \"c\"\nversion = \"0.1.0\"\nedition = \"2021\"\n[dependencies]\nrand = \"0.7\"\nanyhow = \"=1.0.80\"\n")
            try temp.write("rust/src/main.rs", "fn main() {}\n")
            let folder = manifest.deletingLastPathComponent()
            _ = try runner.run("cargo", arguments: ["generate-lockfile"], in: folder)
            _ = try runner.run("cargo", arguments: ["update", "-p", "rand", "--precise", "0.7.0"], in: folder)
            let backend = CargoBackend(manifestURL: manifest, runner: runner)
            let result = await backend.check(graph: try backend.readGraph(), http: http)
            let names = result.updates.map(\.packageID)
            #expect(names.contains("anyhow 1.0.80"))
            #expect(result.updates.first { $0.packageID == "rand 0.7.0" }?.compatible == "0.7.3")
        }
    }
}
