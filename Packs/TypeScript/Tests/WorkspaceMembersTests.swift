/**
    @file WorkspaceMembersTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for workspace members in JavaScript projects.
    @details
    Finding members from patterns (a star, two stars, literal folders,
    "!" excluding, node_modules and folders without package.json left
    out; Yarn's object form; pnpm-workspace.yaml). One workspace (a root
    with packages/app depending on chalk and its sibling packages/lib,
    which depends on has-flag) read from the lockfiles npm, pnpm, Yarn 1
    and Yarn 4 wrote for it: each member's dependencies resolved, a
    sibling dependency resolved to the member's package, members and
    their dependencies left out of the indirect packages, required by
    the members. The commands for a member's changes, and Yarn's need of
    a member's name.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import TypeScriptPack

/// The Fixtures folder beside this file
private let fixtures = PackageFixtures()

@Suite("Workspace members")
struct WorkspaceMembersTests {

    static let root = #"{"name": "mono", "version": "1.0.0", "private": true, "workspaces": ["packages/*"], "devDependencies": {"is-number": "^7.0.0"}}"#
    static let lib = #"{"name": "@mono/lib", "version": "1.0.0", "dependencies": {"has-flag": "^4.0.0"}}"#

    static func app(_ sibling: String) -> String {
        #"{"name": "@mono/app", "version": "1.0.0", "dependencies": {"@mono/lib": ""# + sibling + #"", "chalk": "^4.1.0"}}"#
    }

    /// @brief A workspace's folders, with its lockfile.
    static func workspace(sibling: String, files: [String: String]) throws -> PackageTempFolder {
        let temp = try PackageTempFolder()
        try temp.write("package.json", root)
        try temp.write("packages/app/package.json", app(sibling))
        try temp.write("packages/lib/package.json", lib)
        for (path, text) in files {
            try temp.write(path, text)
        }
        return temp
    }

    /// @brief What every backend's graph of the workspace shows.
    static func expectWorkspace(_ graph: PackageGraph, libID: String, chalkID: String) throws {
        #expect(graph.dependencies.map(\.name) == ["is-number"])
        #expect(graph.dependencies.first?.resolvedID != nil)
        #expect(graph.members.map(\.path) == ["packages/app", "packages/lib"])
        #expect(graph.members.map(\.name) == ["@mono/app", "@mono/lib"])
        let app = try #require(graph.member("packages/app"))
        #expect(app.dependencies.map(\.name) == ["@mono/lib", "chalk"])
        #expect(app.dependency(named: "@mono/lib")?.resolvedID == libID)
        #expect(app.dependency(named: "chalk")?.resolvedID == chalkID)
        let lib = try #require(graph.member("packages/lib"))
        #expect(lib.packageID == libID)
        #expect(lib.dependency(named: "has-flag")?.resolvedID != nil)
        #expect(lib.manifestURL.lastPathComponent == "package.json")
        #expect(graph.package(libID)?.source == .path("packages/lib"))
        // Members and the members' own dependencies aren't indirect
        #expect(graph.indirectPackages.map(\.name) == ["ansi-styles", "color-convert", "color-name", "supports-color"])
        #expect(graph.requiredBy(chalkID) == ["@mono/app"])
        let hasFlag = try #require(lib.dependency(named: "has-flag")?.resolvedID)
        #expect(graph.requiredBy(hasFlag).contains("@mono/lib"))
        #expect(graph.requiredBy(hasFlag).contains("supports-color"))
    }

    // MARK: - Finding Members

    @Test func patternsFindMemberFolders() throws {
        let temp = try PackageTempFolder()
        defer { temp.remove() }
        try temp.write("packages/a/package.json", "{}")
        try temp.write("packages/b/package.json", "{}")
        try temp.write("packages/notes/README.md", "")
        try temp.write("packages/a/node_modules/x/package.json", "{}")
        try temp.write("apps/web/site/package.json", "{}")
        try temp.write("tools/cli/package.json", "{}")
        try temp.write(".hidden/package.json", "{}")
        func folders(_ patterns: [String]) -> [String] {
            PackageWorkspaces.folders(matching: patterns, in: temp.url)
        }
        #expect(folders(["packages/*"]) == ["packages/a", "packages/b"])
        #expect(folders(["packages/*", "!packages/b"]) == ["packages/a"])
        #expect(folders(["apps/**"]) == ["apps/web/site"])
        #expect(folders(["./tools/cli/", "packages/a"]) == ["packages/a", "tools/cli"])
        #expect(folders(["pack*/[ab]"]) == ["packages/a", "packages/b"])
        // The root, node_modules, hidden folders and escapes aren't members
        #expect(folders(["**"]) == ["apps/web/site", "packages/a", "packages/b", "tools/cli"])
        #expect(folders(["../x", "."]).isEmpty)
        #expect(PackageWorkspaces.patterns(in: ["workspaces": ["a/*"]]) == ["a/*"])
        #expect(PackageWorkspaces.patterns(in: ["workspaces": ["packages": ["b/*"], "nohoist": ["x"]]]) == ["b/*"])
        #expect(PackageWorkspaces.patterns(in: [:]).isEmpty)
        #expect(PackageWorkspaces.pnpmPatterns("packages:\n  - 'packages/*'\n  - \"!**/test/**\"\n") == ["packages/*", "!**/test/**"])
        let unnamed = try #require(PackageWorkspaces.readMember("packages/a", in: temp.url))
        #expect(unnamed.name == "a")
        #expect(!unnamed.hasName)
    }

    // MARK: - Each Package Manager

    @Test func npmWorkspace() throws {
        let temp = try Self.workspace(sibling: "*", files: ["package-lock.json": try fixtures.text("workspace-npm-lock.json")])
        defer { temp.remove() }
        let graph = try NPMBackend(manifestURL: temp.url.appendingPathComponent("package.json"), runner: FakePackageToolRunner()).readGraph()
        try Self.expectWorkspace(graph, libID: "node_modules/@mono/lib", chalkID: "node_modules/chalk")
        #expect(graph.member("packages/app")?.packageID == "node_modules/@mono/app")
    }

    @Test func pnpmWorkspace() throws {
        let temp = try Self.workspace(sibling: "workspace:*", files: [
            "pnpm-lock.yaml": try fixtures.text("workspace-pnpm-lock.yaml"),
            "pnpm-workspace.yaml": "packages:\n  - \"packages/*\"\n",
        ])
        defer { temp.remove() }
        let graph = try PNPMBackend(manifestURL: temp.url.appendingPathComponent("package.json"), runner: FakePackageToolRunner()).readGraph()
        try Self.expectWorkspace(graph, libID: "@mono/lib@link:packages/lib", chalkID: "chalk@4.1.2")
        #expect(PNPMBackend.relativePath("../lib", from: "packages/app") == "packages/lib")
        #expect(PNPMBackend.relativePath("./x/../y", from: "a") == "a/y")
    }

    @Test func yarnClassicWorkspace() throws {
        let temp = try Self.workspace(sibling: "*", files: ["yarn.lock": try fixtures.text("workspace-yarn-v1.lock")])
        defer { temp.remove() }
        let graph = try YarnBackend(manifestURL: temp.url.appendingPathComponent("package.json"), runner: FakePackageToolRunner()).readGraph()
        try Self.expectWorkspace(graph, libID: "@mono/lib@workspace:packages/lib", chalkID: "chalk@4.1.2")
        #expect(graph.package("@mono/lib@workspace:packages/lib")?.version == "1.0.0")
    }

    @Test func yarnModernWorkspace() throws {
        let temp = try Self.workspace(sibling: "workspace:*", files: ["yarn.lock": try fixtures.text("workspace-yarn-berry.lock")])
        defer { temp.remove() }
        let graph = try YarnBackend(manifestURL: temp.url.appendingPathComponent("package.json"), runner: FakePackageToolRunner()).readGraph()
        try Self.expectWorkspace(graph, libID: "@mono/lib@workspace:packages/lib", chalkID: "chalk@npm:4.1.2")
        #expect(graph.member("packages/app")?.packageID == "@mono/app@workspace:packages/app")
        // A workspace's own lock entry gives its dependencies
        #expect(graph.package("@mono/lib@workspace:packages/lib")?.dependencies == ["has-flag@npm:4.0.0"])
    }

    @Test func membersWithoutALockfile() throws {
        let temp = try Self.workspace(sibling: "*", files: [:])
        defer { temp.remove() }
        let graph = try NPMBackend(manifestURL: temp.url.appendingPathComponent("package.json"), runner: FakePackageToolRunner()).readGraph()
        #expect(!graph.isResolved)
        #expect(graph.members.map(\.name) == ["@mono/app", "@mono/lib"])
        #expect(graph.members.allSatisfy { $0.dependencies.allSatisfy { $0.resolvedID == nil } })
    }

    // MARK: - Commands

    static let member = PackageMember(name: "@mono/app", path: "packages/app", manifestURL: URL(fileURLWithPath: "/w/packages/app/package.json"), dependencies: [
        PackageDependency(name: "chalk", rule: .requirement("^4.1.0"), kind: .normal),
    ])

    static var graph: PackageGraph {
        var graph = PackageGraph(rootName: "mono", dependencies: [])
        graph.members = [member]
        return graph
    }

    static func commandLines(_ command: PackageCommand) -> [[String]] {
        command.steps.map { [$0.executable] + $0.arguments }
    }

    @Test func npmMemberCommands() throws {
        let backend = NPMBackend(manifestURL: URL(fileURLWithPath: "/w/package.json"), runner: FakePackageToolRunner())
        func run(_ change: PackageChange) throws -> [[String]] {
            Self.commandLines(try backend.command(for: change, graph: Self.graph, manifest: "", member: Self.member))
        }
        #expect(try run(.add(PackageSpec(name: "lodash", rule: .upToNextMajor("4.17.0")), kind: .dev)) == [["npm", "install", "lodash@^4.17.0", "--save-dev", "--workspace", "packages/app"]])
        #expect(try run(.remove(name: "chalk", kind: .normal)) == [["npm", "uninstall", "chalk", "--workspace", "packages/app"]])
        #expect(try run(.changeRule(name: "chalk", kind: .normal, rule: .requirement("^5.0.0"))) == [["npm", "install", "chalk@^5.0.0", "--workspace", "packages/app"]])
        #expect(try run(.update(names: ["chalk"])) == [["npm", "update", "chalk"]])
        #expect(try run(.resolve) == [["npm", "install"]])
        // The member's own dependency, not the root's
        #expect(throws: PackageError.self) { try run(.changeRule(name: "is-number", kind: .dev, rule: .requirement("^7"))) }
    }

    @Test func pnpmMemberCommands() throws {
        let backend = PNPMBackend(manifestURL: URL(fileURLWithPath: "/w/package.json"), runner: FakePackageToolRunner())
        func run(_ change: PackageChange) throws -> [[String]] {
            Self.commandLines(try backend.command(for: change, graph: Self.graph, manifest: "", member: Self.member))
        }
        #expect(try run(.add(PackageSpec(name: "lodash"), kind: .normal)) == [["pnpm", "--filter", "./packages/app", "add", "lodash"]])
        #expect(try run(.remove(name: "chalk", kind: .normal)) == [["pnpm", "--filter", "./packages/app", "remove", "chalk"]])
        #expect(try run(.changeRule(name: "chalk", kind: .normal, rule: .exact("5.3.0"))) == [["pnpm", "--filter", "./packages/app", "add", "chalk@5.3.0", "--save-exact"]])
        #expect(try run(.update(names: [])) == [["pnpm", "update"]])
    }

    @Test func yarnMemberCommands() throws {
        for modern in [false, true] {
            func run(_ change: PackageChange, member: PackageMember = Self.member) throws -> [[String]] {
                Self.commandLines(try YarnBackend.command(for: change, graph: Self.graph, modern: modern, member: member))
            }
            #expect(try run(.add(PackageSpec(name: "lodash"), kind: .dev)) == [["yarn", "workspace", "@mono/app", "add", "lodash", "--dev"]])
            #expect(try run(.remove(name: "chalk", kind: .normal)) == [["yarn", "workspace", "@mono/app", "remove", "chalk"]])
            #expect(try run(.changeRule(name: "chalk", kind: .normal, rule: .requirement("^5.0.0"))) == [["yarn", "workspace", "@mono/app", "add", "chalk@^5.0.0"]])
            #expect(try run(.resolve) == [["yarn", "install"]])
            // Yarn names a workspace by its package name
            var unnamed = Self.member
            unnamed.hasName = false
            #expect(throws: PackageError.self) { try run(.add(PackageSpec(name: "lodash"), kind: .normal), member: unnamed) }
        }
    }
}
