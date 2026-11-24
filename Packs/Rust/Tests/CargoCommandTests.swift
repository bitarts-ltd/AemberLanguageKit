/**
    @file CargoCommandTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Tests for the commands that change a Cargo crate's dependencies.
    @details
    Add with requirements, paths and git, remove, update by crate, a
    renamed dependency's rule change, fetch, and a virtual workspace
    refused. Moved from Aember's PackageCommandTests with the Cargo
    backend.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import RustPack

/// The Fixtures folder beside this file
private let fixtures = PackageFixtures()

@Suite("Cargo commands")
struct CargoCommandTests {

    private let root = URL(fileURLWithPath: "/work/App")
    private let runner = FakePackageToolRunner()

    private func arguments(_ command: PackageCommand) -> [[String]] {
        command.steps.map { [$0.executable] + $0.arguments }
    }

    // MARK: - Cargo

    private var cargo: CargoBackend {
        CargoBackend(manifestURL: root.appendingPathComponent("Cargo.toml"), runner: runner)
    }

    private var cargoGraph: PackageGraph {
        PackageGraph(
            rootName: "app",
            dependencies: [
                PackageDependency(name: "serde", rule: .requirement("1.0"), resolvedID: "serde 1.0.200"),
                PackageDependency(name: "json", rule: .requirement("1"), resolvedID: "serde_json 1.0.100"),
                PackageDependency(name: "tempfile", rule: .requirement("3"), kind: .dev),
                PackageDependency(name: "local", rule: .path("../local"), location: "/work/local"),
            ],
            packages: [
                ResolvedPackage(id: "serde 1.0.200", name: "serde", version: "1.0.200"),
                ResolvedPackage(id: "serde_json 1.0.100", name: "serde_json", version: "1.0.100"),
            ]
        )
    }

    @Test func cargoAdds() throws {
        func add(_ spec: PackageSpec, _ kind: DependencyKind = .normal) throws -> [String] {
            try arguments(cargo.command(for: .add(spec, kind: kind), graph: cargoGraph, manifest: ""))[0]
        }
        #expect(try add(PackageSpec(name: "rand")) == ["cargo", "add", "rand"])
        #expect(try add(PackageSpec(name: "rand", rule: .requirement("0.8"))) == ["cargo", "add", "rand@0.8"])
        #expect(try add(PackageSpec(name: "rand", rule: .exact("0.8.5")), .dev) == ["cargo", "add", "rand@=0.8.5", "--dev"])
        #expect(try add(PackageSpec(name: "cc", rule: .upToNextMajor("1.0")), .build) == ["cargo", "add", "cc@^1.0", "--build"])
        #expect(try add(PackageSpec(name: "log"), .optional) == ["cargo", "add", "log", "--optional"])
        #expect(try add(PackageSpec(name: "tools", rule: .path("../tools"))) == ["cargo", "add", "--path", "../tools"])
        #expect(try add(PackageSpec(name: "https://x/y.git", rule: .branch("main")))
            == ["cargo", "add", "--git", "https://x/y.git", "--branch", "main"])
        #expect(throws: PackageError.self) {
            try add(PackageSpec(name: "rand", rule: .range("1", "2")))
        }
    }

    @Test func cargoRemovesUpdatesAndFetches() throws {
        #expect(arguments(try cargo.command(for: .remove(name: "serde", kind: .normal), graph: cargoGraph, manifest: ""))
            == [["cargo", "remove", "serde"]])
        #expect(arguments(try cargo.command(for: .remove(name: "tempfile", kind: .dev), graph: cargoGraph, manifest: ""))
            == [["cargo", "remove", "tempfile", "--dev"]])
        // Updated by crate, not by the renamed key
        #expect(arguments(try cargo.command(for: .update(names: ["json", "serde"]), graph: cargoGraph, manifest: ""))
            == [["cargo", "update", "serde_json", "serde"]])
        #expect(arguments(try cargo.command(for: .update(names: []), graph: cargoGraph, manifest: ""))
            == [["cargo", "update"]])
        #expect(arguments(try cargo.command(for: .resolve, graph: cargoGraph, manifest: "")) == [["cargo", "fetch"]])
    }

    @Test func cargoChangesRules() throws {
        #expect(arguments(try cargo.command(
            for: .changeRule(name: "serde", kind: .normal, rule: .requirement("1.0.210")),
            graph: cargoGraph,
            manifest: ""
        )) == [["cargo", "add", "serde@1.0.210"]])
        #expect(arguments(try cargo.command(
            for: .changeRule(name: "json", kind: .normal, rule: .requirement("1.0.120")),
            graph: cargoGraph,
            manifest: ""
        )) == [["cargo", "add", "serde_json@1.0.120", "--rename", "json"]])
        #expect(arguments(try cargo.command(
            for: .changeRule(name: "tempfile", kind: .dev, rule: .requirement("3.10")),
            graph: cargoGraph,
            manifest: ""
        )) == [["cargo", "add", "tempfile@3.10", "--dev"]])
        #expect(throws: PackageError.self) {
            try cargo.command(for: .changeRule(name: "local", kind: .normal, rule: .requirement("1")), graph: cargoGraph, manifest: "")
        }
    }

    @Test func cargoVirtualWorkspaceOnlyUpdatesAndResolves() throws {
        var graph = cargoGraph
        graph.isWorkspaceOnly = true
        #expect(cargo.capabilities(for: graph) == [.update, .resolve])
        #expect(throws: PackageError.self) {
            try cargo.command(for: .remove(name: "serde", kind: .normal), graph: graph, manifest: "")
        }
        #expect(arguments(try cargo.command(for: .update(names: []), graph: graph, manifest: "")) == [["cargo", "update"]])
    }
}
