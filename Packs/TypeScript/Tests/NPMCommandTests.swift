/**
    @file NPMCommandTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Tests for the commands that change an npm package's dependencies.
    @details
    install, uninstall, update, a dev dependency's rule change, build
    dependencies refused, and values that would read as options
    refused. Moved from Aember's PackageCommandTests with the npm
    backend.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import TypeScriptPack

/// The Fixtures folder beside this file
private let fixtures = PackageFixtures()

@Suite("npm commands")
struct NPMCommandTests {

    private let root = URL(fileURLWithPath: "/work/App")
    private let runner = FakePackageToolRunner()

    private func arguments(_ command: PackageCommand) -> [[String]] {
        command.steps.map { [$0.executable] + $0.arguments }
    }

    // MARK: - npm

    private var npm: NPMBackend {
        NPMBackend(manifestURL: root.appendingPathComponent("package.json"), runner: runner)
    }

    private var npmGraph: PackageGraph {
        PackageGraph(rootName: "site", dependencies: [
            PackageDependency(name: "react", rule: .requirement("^18.2.0")),
            PackageDependency(name: "vite", rule: .requirement("^5.0.0"), kind: .dev),
            PackageDependency(name: "fsevents", rule: .requirement("^2.3.0"), kind: .optional),
        ])
    }

    @Test func npmInstallsUninstallsAndUpdates() throws {
        func run(_ change: PackageChange) throws -> [[String]] {
            try arguments(npm.command(for: change, graph: npmGraph, manifest: "{}"))
        }
        #expect(try run(.add(PackageSpec(name: "lodash"), kind: .normal)) == [["npm", "install", "lodash"]])
        #expect(try run(.add(PackageSpec(name: "lodash", rule: .requirement("^4.17.0")), kind: .dev))
            == [["npm", "install", "lodash@^4.17.0", "--save-dev"]])
        #expect(try run(.add(PackageSpec(name: "lodash", rule: .exact("4.17.21")), kind: .optional))
            == [["npm", "install", "lodash@4.17.21", "--save-exact", "--save-optional"]])
        #expect(try run(.add(PackageSpec(name: "kit", rule: .path("../kit")), kind: .normal)) == [["npm", "install", "../kit"]])
        #expect(throws: PackageError.self) {
            try run(.add(PackageSpec(name: "lodash"), kind: .build))
        }
        #expect(try run(.remove(name: "react", kind: .normal)) == [["npm", "uninstall", "react"]])
        #expect(try run(.update(names: ["react"])) == [["npm", "update", "react"]])
        #expect(try run(.resolve) == [["npm", "install"]])
    }

    @Test func npmRuleChangeKeepsTheSection() throws {
        #expect(arguments(try npm.command(
            for: .changeRule(name: "vite", kind: .dev, rule: .requirement("^5.4.0")),
            graph: npmGraph,
            manifest: "{}"
        )) == [["npm", "install", "vite@^5.4.0", "--save-dev"]])
        #expect(arguments(try npm.command(
            for: .changeRule(name: "react", kind: .normal, rule: .requirement("18.3.1")),
            graph: npmGraph,
            manifest: "{}"
        )) == [["npm", "install", "react@18.3.1"]])
    }

    @Test func optionLikeValuesAreRefused() {
        #expect(throws: PackageError.self) {
            try npm.command(for: .remove(name: "--global", kind: .normal), graph: npmGraph, manifest: "{}")
        }
    }
}
