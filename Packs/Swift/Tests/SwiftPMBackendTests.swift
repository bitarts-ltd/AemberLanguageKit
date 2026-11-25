/**
    @file SwiftPMBackendTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for reading Swift packages' dependencies.
    @details
    dump-package's dependency forms (url with every rule, registry
    identity, path) as rules; Package.resolved versions 1, 2 and 3 with
    version, branch and registry pins; show-dependencies' tree; the
    graph from pins alone, with the tree, and for path dependencies
    only; readGraph running show-dependencies only once the package was
    resolved; and finding a dependency's declaration in Package.swift by
    URL, registry identity and path, past comments.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import SwiftPack

/// The Fixtures folder beside this file
private let fixtures = PackageFixtures()

@Suite("SwiftPM backend")
struct SwiftPMBackendTests {

    static let folder = URL(fileURLWithPath: "/work/Forms")

    @Test func dumpReadsEveryForm() throws {
        let dump = try SwiftPMBackend.parseDump(fixtures.data("swiftpm-dump-forms.json"), folder: Self.folder)
        #expect(dump.name == "Forms")
        #expect(dump.dependencies.map(\.name) == [
            "swift-collections", "swift-nio", "swift-argument-parser", "swift-algorithms",
            "swift-atomics", "swift-numerics", "mona.LinkedList", "leaf",
        ])
        #expect(dump.dependencies.map(\.rule) == [
            .upToNextMajor("1.1.0"),
            .upToNextMinor("2.65.0"),
            .exact("1.5.0"),
            .branch("main"),
            .revision("abcdef0123456789abcdef0123456789abcdef01"),
            .range("1.0.0", "1.2.0"),
            .upToNextMajor("1.2.0"),
            .path("../Leaf"),
        ])
        #expect(dump.dependencies[0].location == "https://github.com/apple/swift-collections.git")
        #expect(dump.dependencies[6].location == "mona.LinkedList")
        #expect(dump.dependencies[7].location == "/work/Leaf")
    }

    @Test func dumpRejectsOtherJSON() {
        #expect(throws: PackageError.unreadable("dump-package")) {
            try SwiftPMBackend.parseDump(Data("{\"x\": 1}".utf8), folder: Self.folder)
        }
        #expect(throws: PackageError.unreadable("dump-package")) {
            try SwiftPMBackend.parseDump(Data("not json".utf8), folder: Self.folder)
        }
    }

    @Test func nextVersions() {
        #expect(SwiftPMBackend.nextVersion(after: "1.2.3", major: true) == "2.0.0")
        #expect(SwiftPMBackend.nextVersion(after: "1.2.3", major: false) == "1.3.0")
        #expect(SwiftPMBackend.nextVersion(after: "main", major: true) == nil)
    }

    @Test func resolvedVersion3() throws {
        let pins = try SwiftPMBackend.parseResolved(fixtures.data("swiftpm-resolved-forms.json"))
        #expect(pins.map(\.identity) == ["mona.linkedlist", "swift-algorithms", "swift-collections"])
        #expect(pins[0].kind == "registry")
        #expect(pins[0].version == "1.2.3")
        #expect(pins[1].branch == "main")
        #expect(pins[1].version == nil)
        #expect(pins[2].version == "1.1.4")
        let real = try SwiftPMBackend.parseResolved(fixtures.data("swiftpm-resolved-v3.json"))
        #expect(!real.isEmpty)
        #expect(real.allSatisfy { $0.kind == "remoteSourceControl" && $0.version != nil })
    }

    @Test func resolvedVersion2() throws {
        let pins = try SwiftPMBackend.parseResolved(fixtures.data("swiftpm-resolved-v2.json"))
        #expect(pins == [SwiftPMBackend.Pin(
            identity: "tree-sitter",
            kind: "remoteSourceControl",
            location: "https://github.com/tree-sitter/tree-sitter",
            version: "0.25.10",
            revision: "da6fe9beb4f7f67beb75914ca8e0d48ae48d6406",
            branch: nil
        )])
    }

    @Test func resolvedVersion1() throws {
        let pins = try SwiftPMBackend.parseResolved(fixtures.data("swiftpm-resolved-v1.json"))
        #expect(pins.map(\.identity) == ["swift-argument-parser"])
        #expect(pins[0].version == "1.0.2")
    }

    @Test func showDependenciesTree() throws {
        let tree = try SwiftPMBackend.parseShowDependencies(fixtures.data("swiftpm-show-dependencies.json"))
        #expect(tree.identity == "app")
        #expect(tree.dependencies.map(\.identity) == ["mid", "leaf"])
        #expect(tree.dependencies[0].dependencies.map(\.identity) == ["leaf"])
        #expect(tree.dependencies[0].path == "/work/Mid")
    }

    @Test func graphFromPinsAlone() throws {
        let dump = try SwiftPMBackend.parseDump(fixtures.data("swiftpm-dump-forms.json"), folder: Self.folder)
        let pins = try SwiftPMBackend.parseResolved(fixtures.data("swiftpm-resolved-forms.json"))
        let graph = SwiftPMBackend.graph(dump: dump, pins: pins, tree: nil, checkouts: URL(fileURLWithPath: "/nonexistent"))
        #expect(graph.isResolved)
        #expect(!graph.hasEdges)
        let resolved = graph.dependencies.map { $0.resolvedID }
        // Collections, algorithms and the registry package pinned (its
        // identity in another case), the leaf by path; the rest aren't
        // in this Package.resolved
        #expect(resolved == ["swift-collections", nil, nil, "swift-algorithms", nil, nil, "mona.linkedlist", "leaf"])
        #expect(graph.package("leaf")?.source == .path("/work/Leaf"))
        #expect(graph.package("swift-collections")?.source == .git("https://github.com/apple/swift-collections.git"))
        #expect(graph.package("mona.linkedlist")?.source == .registry(nil))
        #expect(graph.indirectPackages.isEmpty)
    }

    @Test func graphWithTheTree() throws {
        let dump = try SwiftPMBackend.parseDump(fixtures.data("swiftpm-dump-app.json"), folder: URL(fileURLWithPath: "/work/App"))
        let tree = try SwiftPMBackend.parseShowDependencies(fixtures.data("swiftpm-show-dependencies.json"))
        let graph = SwiftPMBackend.graph(dump: dump, pins: nil, tree: tree, checkouts: URL(fileURLWithPath: "/nonexistent"))
        #expect(graph.isResolved)
        #expect(graph.hasEdges)
        #expect(graph.dependencies.map(\.rule) == [.path("../Mid"), .path("../Leaf")])
        #expect(graph.dependencies.map(\.resolvedID) == ["mid", "leaf"])
        #expect(graph.children(of: "mid").map(\.id) == ["leaf"])
        #expect(graph.requiredBy("leaf") == ["App", "mid"])
        #expect(graph.package("mid")?.checkout == URL(fileURLWithPath: "/work/Mid"))
    }

    @Test func pathDependenciesNeedNoResolvedFile() throws {
        let dump = try SwiftPMBackend.parseDump(fixtures.data("swiftpm-dump-app.json"), folder: URL(fileURLWithPath: "/work/App"))
        let graph = SwiftPMBackend.graph(dump: dump, pins: nil, tree: nil, checkouts: URL(fileURLWithPath: "/nonexistent"))
        #expect(graph.isResolved)
        #expect(graph.dependencies.allSatisfy { $0.resolvedID != nil })
        let forms = try SwiftPMBackend.parseDump(fixtures.data("swiftpm-dump-forms.json"), folder: Self.folder)
        #expect(!SwiftPMBackend.graph(dump: forms, pins: nil, tree: nil, checkouts: URL(fileURLWithPath: "/nonexistent")).isResolved)
    }

    @Test func readGraphRunsShowDependenciesOnlyOnceResolved() throws {
        let temp = try PackageTempFolder()
        defer { temp.remove() }
        let manifest = try temp.write("Package.swift", "// swift-tools-version: 6.0\n")
        let runner = FakePackageToolRunner()
        runner.answer("swift package dump-package", with: try fixtures.data("swiftpm-dump-app.json"))
        runner.answer("swift package show-dependencies --format json", with: try fixtures.data("swiftpm-show-dependencies.json"))
        let backend = SwiftPMBackend(manifestURL: manifest, runner: runner)

        let before = try backend.readGraph()
        #expect(!before.hasEdges)
        #expect(runner.commands.map(\.line) == ["swift package dump-package"])
        #expect(runner.commands.first?.folder.standardizedFileURL.path == temp.url.standardizedFileURL.path)

        try temp.write(".build/workspace-state.json", "{}")
        let after = try backend.readGraph()
        #expect(after.hasEdges)
        #expect(runner.commands.map(\.line).last == "swift package show-dependencies --format json")
    }

    @Test func readGraphReportsTheTool() throws {
        let temp = try PackageTempFolder()
        defer { temp.remove() }
        let manifest = try temp.write("Package.swift", "")
        let runner = FakePackageToolRunner()
        runner.answer("swift package dump-package", with: Data(), status: 1, error: "error: manifest parse error\n")
        let backend = SwiftPMBackend(manifestURL: manifest, runner: runner)
        #expect(throws: PackageError.toolFailed(command: "swift package dump-package", message: "error: manifest parse error\n")) {
            try backend.readGraph()
        }
        runner.installed = []
        #expect(backend.checkTool() == .missing)
        #expect(throws: PackageError.toolMissing("swift")) {
            try backend.readGraph()
        }
    }

    static let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Forms",
            dependencies: [
                // .package(url: "https://github.com/apple/swift-nio", from: "2.0.0"),
                .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
                .package(
                    url: "https://github.com/apple/swift-nio",
                    .upToNextMinor(from: "2.65.0")
                ),
                .package(id: "mona.LinkedList", from: "1.2.0"),
                .package(path: "../Leaf"),
            ],
            targets: [.target(name: "Forms")]
        )
        """

    @Test func declarationByURLIdentityAndPath() throws {
        let dump = try SwiftPMBackend.parseDump(fixtures.data("swiftpm-dump-forms.json"), folder: Self.folder)
        func line(_ name: String) -> Int? {
            let dependency = dump.dependencies.first { $0.name == name }!
            return SwiftPMBackend.declarationLine(of: dependency, in: Self.manifest, folder: Self.folder)
        }
        #expect(line("swift-collections") == 7)
        #expect(line("swift-nio") == 9)
        #expect(line("mona.LinkedList") == 12)
        #expect(line("leaf") == 13)
        #expect(line("swift-algorithms") == nil)
    }

    @Test func stringLiteralsSkipEscapes() {
        #expect(SwiftPMBackend.stringLiterals(in: #"a "one" b "t\"wo" c"#) == ["one", #"t"wo"#])
        #expect(SwiftPMBackend.stringLiterals(in: "none").isEmpty)
        #expect(SwiftPMBackend.stringLiterals(in: #""https://a/b" // "comment""#) == ["https://a/b"])
        #expect(SwiftPMBackend.stringLiterals(in: #"// .package(url: "x")"#).isEmpty)
    }

    @Test func identityOfLocation() {
        #expect(SwiftPMBackend.identity(ofLocation: "https://github.com/Apple/Swift-NIO.git") == "swift-nio")
        #expect(SwiftPMBackend.identity(ofLocation: "/work/Leaf") == "leaf")
    }
}
