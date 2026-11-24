/**
    @file SwiftPMCommandTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Tests for the commands that change Swift packages.
    @details
    Every PackageChange and version rule for SwiftPM: add-dependency
    with each rule and --type path and registry, products, update,
    resolve, Remove's manifest edit, a rule change's remove-then-add,
    values that would read as options, and the capabilities. Moved
    from Aember's PackageCommandTests with the backend.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import SwiftPack

@Suite("SwiftPM commands")
struct SwiftPMCommandTests {

    private let root = URL(fileURLWithPath: "/work/App")
    private let runner = FakePackageToolRunner()

    private func arguments(_ command: PackageCommand) -> [[String]] {
        command.steps.map { [$0.executable] + $0.arguments }
    }

    private var swift: SwiftPMBackend {
        SwiftPMBackend(manifestURL: root.appendingPathComponent("Package.swift"), runner: runner)
    }

    private let swiftManifest = """
        let package = Package(
            name: "App",
            dependencies: [
                .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
            ],
            targets: [
                .target(name: "App", dependencies: [.product(name: "NIO", package: "swift-nio")]),
            ]
        )
        """

    private var swiftGraph: PackageGraph {
        PackageGraph(rootName: "App", dependencies: [
            PackageDependency(
                name: "swift-nio",
                rule: .upToNextMajor("2.65.0"),
                location: "https://github.com/apple/swift-nio.git"
            ),
            PackageDependency(name: "kit", rule: .path("../Kit"), location: "/work/Kit"),
        ])
    }

    @Test(arguments: [
        (VersionRule.upToNextMajor("1.0.0"), ["--from", "1.0.0"]),
        (.upToNextMinor("1.2.0"), ["--up-to-next-minor-from", "1.2.0"]),
        (.exact("1.2.3"), ["--exact", "1.2.3"]),
        (.range("1.0.0", "1.5.0"), ["--from", "1.0.0", "--to", "1.5.0"]),
        (.branch("main"), ["--branch", "main"]),
        (.revision("abc123"), ["--revision", "abc123"]),
    ])
    func swiftAddsByURLWithEachRule(rule: VersionRule, flags: [String]) throws {
        let spec = PackageSpec(name: "https://github.com/apple/swift-algorithms.git", rule: rule)
        let command = try swift.command(for: .add(spec, kind: .normal), graph: swiftGraph, manifest: swiftManifest)
        #expect(command.manifestText == nil)
        #expect(arguments(command) == [
            ["swift", "package", "add-dependency", "https://github.com/apple/swift-algorithms.git"] + flags,
            ["swift", "package", "resolve"],
        ])
    }

    @Test func swiftAddsPathRegistryAndProducts() throws {
        let path = PackageSpec(name: "../Tools", rule: .path("../Tools"))
        #expect(arguments(try swift.command(for: .add(path, kind: .normal), graph: swiftGraph, manifest: swiftManifest))[0]
            == ["swift", "package", "add-dependency", "../Tools", "--type", "path"])

        let registry = PackageSpec(name: "Scope.Name", rule: .upToNextMajor("1.0.0"), products: [("Name", "App")])
        let command = try swift.command(for: .add(registry, kind: .normal), graph: swiftGraph, manifest: swiftManifest)
        #expect(arguments(command) == [
            ["swift", "package", "add-dependency", "Scope.Name", "--from", "1.0.0", "--type", "registry"],
            ["swift", "package", "add-target-dependency", "Name", "App", "--package", "scope.name"],
            ["swift", "package", "resolve"],
        ])

        let url = PackageSpec(name: "https://github.com/apple/swift-algorithms.git", rule: .exact("1.2.0"), products: [("Algorithms", "App")])
        #expect(arguments(try swift.command(for: .add(url, kind: .normal), graph: swiftGraph, manifest: swiftManifest))[1]
            == ["swift", "package", "add-target-dependency", "Algorithms", "App", "--package", "swift-algorithms"])
    }

    @Test func swiftRefusesWhatItCantAdd() {
        let noRule = PackageSpec(name: "https://github.com/apple/swift-algorithms.git", rule: nil)
        #expect(throws: PackageError.self) {
            try swift.command(for: .add(noRule, kind: .normal), graph: swiftGraph, manifest: swiftManifest)
        }
        let dev = PackageSpec(name: "https://x/y.git", rule: .exact("1.0.0"))
        #expect(throws: PackageError.self) {
            try swift.command(for: .add(dev, kind: .dev), graph: swiftGraph, manifest: swiftManifest)
        }
        let requirement = PackageSpec(name: "https://x/y.git", rule: .requirement("^1"))
        #expect(throws: PackageError.self) {
            try swift.command(for: .add(requirement, kind: .normal), graph: swiftGraph, manifest: swiftManifest)
        }
    }

    @Test func swiftUpdatesAndResolves() throws {
        #expect(arguments(try swift.command(for: .update(names: []), graph: swiftGraph, manifest: swiftManifest))
            == [["swift", "package", "update"]])
        #expect(arguments(try swift.command(for: .update(names: ["swift-nio"]), graph: swiftGraph, manifest: swiftManifest))
            == [["swift", "package", "update", "swift-nio"]])
        #expect(arguments(try swift.command(for: .resolve, graph: swiftGraph, manifest: swiftManifest))
            == [["swift", "package", "resolve"]])
    }

    @Test func swiftRemoveEditsTheManifestThenResolves() throws {
        let command = try swift.command(for: .remove(name: "swift-nio", kind: .normal), graph: swiftGraph, manifest: swiftManifest)
        #expect(arguments(command) == [["swift", "package", "resolve"]])
        let text = try #require(command.manifestText)
        #expect(!text.contains("swift-nio"))
        #expect(text.contains("dependencies: []"))
    }

    @Test func swiftRemoveOfAComputedListIsNotWrittenLiterally() {
        let manifest = "let package = Package(name: \"App\", dependencies: deps)"
        #expect(throws: PackageError.notWrittenLiterally("swift-nio")) {
            try swift.command(for: .remove(name: "swift-nio", kind: .normal), graph: swiftGraph, manifest: manifest)
        }
    }

    @Test func swiftRuleChangeRemovesTheDeclarationAndAddsItAgain() throws {
        let command = try swift.command(
            for: .changeRule(name: "swift-nio", kind: .normal, rule: .exact("2.70.0")),
            graph: swiftGraph,
            manifest: swiftManifest
        )
        #expect(arguments(command) == [
            ["swift", "package", "add-dependency", "https://github.com/apple/swift-nio.git", "--exact", "2.70.0"],
            ["swift", "package", "resolve"],
        ])
        let text = try #require(command.manifestText)
        #expect(!text.contains("swift-nio.git"))
        #expect(text.contains(".product(name: \"NIO\", package: \"swift-nio\")"))
        // A path dependency has no rule to change
        #expect(!swift.canChangeRule(of: swiftGraph.dependencies[1]))
        #expect(throws: PackageError.self) {
            try swift.command(for: .changeRule(name: "kit", kind: .normal, rule: .exact("1.0.0")), graph: swiftGraph, manifest: swiftManifest)
        }
    }

    @Test func swiftRegistryRuleChangeKeepsItsType() throws {
        let graph = PackageGraph(rootName: "App", dependencies: [
            PackageDependency(name: "scope.name", rule: .exact("1.0.0"), location: "scope.name"),
        ])
        let manifest = """
            let package = Package(name: "App", dependencies: [
                .package(id: "scope.name", exact: "1.0.0"),
            ])
            """
        let command = try swift.command(
            for: .changeRule(name: "scope.name", kind: .normal, rule: .upToNextMajor("1.1.0")),
            graph: graph,
            manifest: manifest
        )
        #expect(arguments(command)[0] == ["swift", "package", "add-dependency", "scope.name", "--from", "1.1.0", "--type", "registry"])
    }

    @Test func swiftSourceTypes() {
        #expect(SwiftPMBackend.sourceType(of: PackageSpec(name: "https://x/y.git")) == "url")
        #expect(SwiftPMBackend.sourceType(of: PackageSpec(name: "git@github.com:x/y.git")) == "url")
        #expect(SwiftPMBackend.sourceType(of: PackageSpec(name: "../Kit")) == "path")
        #expect(SwiftPMBackend.sourceType(of: PackageSpec(name: "/abs/Kit")) == "path")
        #expect(SwiftPMBackend.sourceType(of: PackageSpec(name: "mona.LinkedList")) == "registry")
        #expect(SwiftPMBackend.sourceType(of: PackageSpec(name: "Kit", rule: .path("Kit"))) == "path")
    }

    @Test func optionLikeValuesAreRefused() {
        #expect(throws: PackageError.self) {
            try swift.command(for: .update(names: ["-x"]), graph: swiftGraph, manifest: swiftManifest)
        }
    }

    @Test func capabilities() {
        #expect(swift.capabilities(for: nil) == [.resolve])
        #expect(swift.capabilities(for: swiftGraph) == .all)
    }
}
