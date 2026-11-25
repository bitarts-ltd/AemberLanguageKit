/**
    @file NPMBackendTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for reading npm packages' dependencies.
    @details
    package.json's sections as kinds, file: requirements as paths;
    package-lock.json v3's packages with Node's lookup (a nested copy
    before the top-level one), links taking their target's version and
    dependencies, scoped names; checkouts in node_modules only when
    installed; no lockfile; readGraph running no tool; and finding a
    dependency's line in package.json by section.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import TypeScriptPack

/// The Fixtures folder beside this file
private let fixtures = PackageFixtures()

@Suite("npm backend")
struct NPMBackendTests {

    static let folder = URL(fileURLWithPath: "/work/web")

    static func graph(folder: URL = folder) throws -> PackageGraph {
        NPMBackend.graph(
            manifest: try fixtures.object("npm-package.json"),
            lock: try fixtures.object("npm-package-lock-v3.json"),
            folder: folder
        )
    }

    @Test func sectionsAreKinds() throws {
        let dependencies = NPMBackend.dependencies(of: try fixtures.object("npm-package.json"))
        #expect(dependencies.map(\.name) == ["clsx", "local-kit", "react", "react-dom", "@typescript-eslint/typescript-estree", "typescript"])
        #expect(dependencies.map(\.kind) == [.normal, .normal, .normal, .normal, .dev, .dev])
        #expect(dependencies[1].rule == .path("../local-kit"))
        #expect(dependencies[2].rule == .requirement("^19.0.0"))
    }

    @Test func lockfileResolvesAsNodeDoes() throws {
        let graph = try Self.graph()
        #expect(graph.rootName == "web-app")
        #expect(graph.isResolved)
        #expect(graph.dependencies.map(\.resolvedID) == [
            "node_modules/clsx", "node_modules/local-kit", "node_modules/react", "node_modules/react-dom",
            "node_modules/@typescript-eslint/typescript-estree", "node_modules/typescript",
        ])
        // Its own nested copy, not the top-level one
        #expect(graph.children(of: "node_modules/@typescript-eslint/typescript-estree").map(\.id) == [
            "node_modules/@typescript-eslint/typescript-estree/node_modules/brace-expansion",
        ])
        // The nested copy finds balanced-match at the top
        #expect(graph.children(of: "node_modules/@typescript-eslint/typescript-estree/node_modules/brace-expansion").map(\.id) == [
            "node_modules/balanced-match",
        ])
        // Peer dependencies count
        #expect(graph.children(of: "node_modules/react-dom").map(\.id) == ["node_modules/scheduler", "node_modules/react"])
        let nested = try #require(graph.package("node_modules/@typescript-eslint/typescript-estree/node_modules/brace-expansion"))
        #expect(nested.name == "brace-expansion")
        #expect(nested.version == "2.0.2")
        #expect(graph.package("node_modules/@typescript-eslint/typescript-estree")?.name == "@typescript-eslint/typescript-estree")
        #expect(graph.indirectPackages.map(\.version) == ["1.0.2", "1.1.12", "2.0.2", "0.27.0"])
    }

    @Test func linksTakeTheirTarget() throws {
        let graph = try Self.graph()
        let link = try #require(graph.package("node_modules/local-kit"))
        #expect(link.version == "2.0.0")
        #expect(link.source == .path("../local-kit"))
        #expect(link.dependencies == ["node_modules/clsx"])
        // The link's target isn't a package of its own
        #expect(graph.package("../local-kit") == nil)
    }

    @Test func checkoutsOnlyWhenInstalled() throws {
        let temp = try PackageTempFolder()
        defer { temp.remove() }
        try temp.write("node_modules/react/package.json", "{}")
        let graph = try Self.graph(folder: temp.url)
        #expect(graph.package("node_modules/react")?.checkout == temp.url.appendingPathComponent("node_modules/react"))
        #expect(graph.package("node_modules/clsx")?.checkout == nil)
    }

    @Test func withoutALockfile() throws {
        let graph = NPMBackend.graph(manifest: try fixtures.object("npm-package.json"), lock: nil, folder: Self.folder)
        #expect(!graph.isResolved)
        #expect(graph.packages.isEmpty)
        #expect(graph.dependencies.allSatisfy { $0.resolvedID == nil })
    }

    @Test func keysAndLookup() {
        #expect(NPMBackend.name(ofKey: "node_modules/a/node_modules/@s/b") == "@s/b")
        let packages: [String: Any] = ["node_modules/x": [:], "node_modules/a/node_modules/x": [:], "node_modules/a": [:]]
        #expect(NPMBackend.resolve("x", from: "node_modules/a", in: packages) == "node_modules/a/node_modules/x")
        #expect(NPMBackend.resolve("x", from: "node_modules/b", in: packages) == "node_modules/x")
        #expect(NPMBackend.resolve("x", from: "", in: packages) == "node_modules/x")
        #expect(NPMBackend.resolve("y", from: "node_modules/a", in: packages) == nil)
    }

    @Test func readGraphRunsNoTool() throws {
        let temp = try PackageTempFolder()
        defer { temp.remove() }
        let manifest = try temp.write("package.json", try fixtures.text("npm-package.json"))
        try temp.write("package-lock.json", try fixtures.text("npm-package-lock-v3.json"))
        let runner = FakePackageToolRunner()
        let backend = NPMBackend(manifestURL: manifest, runner: runner)
        let graph = try backend.readGraph()
        #expect(graph.dependencies.count == 6)
        #expect(runner.commands.isEmpty)
        try temp.write("package.json", "not json")
        #expect(throws: PackageError.unreadable("package.json")) {
            try backend.readGraph()
        }
    }

    @Test func declarationInPackageJSON() throws {
        let text = try fixtures.text("npm-package.json")
        func line(_ name: String, _ kind: DependencyKind) -> Int? {
            NPMBackend.declarationLine(of: PackageDependency(name: name, kind: kind), in: text)
        }
        let lines = text.components(separatedBy: "\n")
        let react = try #require(line("react", .normal))
        #expect(lines[react - 1].contains("\"react\":"))
        let typescript = try #require(line("typescript", .dev))
        #expect(lines[typescript - 1].contains("\"typescript\":"))
        #expect(line("typescript", .normal) == nil)
    }
}
