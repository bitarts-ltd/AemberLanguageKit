/**
    @file NodePackageManagersTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for pnpm and Yarn, and which tool a package.json uses.
    @details
    LockfileText on the YAML lockfiles write and on Yarn 1's format;
    choosing npm, pnpm or Yarn by packageManager and lockfile, one
    backend per package.json; graphs from saved pnpm-lock.yaml (v9 and
    v6), Yarn 1 and Yarn 4 lockfiles of one project (scoped, peer, path
    and optional dependencies), with checkouts only where installed; the
    commands for every change; and the audit reports each prints.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import TypeScriptPack

/// The Fixtures folder beside this file
private let fixtures = PackageFixtures()

@Suite("pnpm and Yarn backends")
struct NodePackageManagersTests {

    static let folder = URL(fileURLWithPath: "/work/app")

    static func manifest() throws -> [String: Any] {
        try fixtures.object("node-package.json")
    }

    static func pnpmGraph(_ fixture: String = "pnpm-lock-v9.yaml", folder: URL = folder) throws -> PackageGraph {
        PNPMBackend.graph(manifest: try manifest(), lock: LockfileText.parse(try fixtures.text(fixture)), folder: folder)
    }

    static func yarnGraph(_ fixture: String, folder: URL = folder) throws -> PackageGraph {
        YarnBackend.graph(manifest: try manifest(), lockText: try fixtures.text(fixture), folder: folder)
    }

    // MARK: - Lockfile Text

    @Test func readsYAMLAsLockfilesWriteIt() {
        let text = """
        lockfileVersion: '9.0'

        # a comment
        importers:

          .:
            dependencies:
              '@s/a':
                specifier: ^1.0.0
                version: 1.0.0
        packages:
          '@s/a@1.0.0':
            resolution: {integrity: sha512-x==, tarball: 'https://h/a.tgz'}
            cpu: [x64, arm64]
            os:
              - darwin
          b@file:kit:
            resolution: {directory: kit, type: directory}
          c@1.0.0: {}
          "d@npm:^1, d@npm:^1.2":
            version: 1.2.0
        """
        let lock = LockfileText.parse(text)
        #expect(lock["lockfileVersion"] as? String == "9.0")
        let importer = (lock["importers"] as? [String: Any])?["."] as? [String: Any]
        let scoped = (importer?["dependencies"] as? [String: Any])?["@s/a"] as? [String: Any]
        #expect(scoped?["version"] as? String == "1.0.0")
        let packages = lock["packages"] as? [String: Any] ?? [:]
        let a = packages["@s/a@1.0.0"] as? [String: Any]
        let resolution = a?["resolution"] as? [String: Any]
        #expect(resolution?["integrity"] as? String == "sha512-x==")
        #expect(resolution?["tarball"] as? String == "https://h/a.tgz")
        #expect(a?["cpu"] as? [String] == ["x64", "arm64"])
        #expect(a?["os"] as? [String] == ["darwin"])
        #expect(((packages["b@file:kit"] as? [String: Any])?["resolution"] as? [String: Any])?["directory"] as? String == "kit")
        #expect((packages["c@1.0.0"] as? [String: Any])?.isEmpty == true)
        #expect(LockfileText.descriptors(ofKey: "d@npm:^1, d@npm:^1.2") == ["d@npm:^1", "d@npm:^1.2"])
        #expect(packages["d@npm:^1, d@npm:^1.2"] != nil)
    }

    @Test func readsYarnClassicFormat() {
        let text = """
        # yarn lockfile v1


        "@s/a@^1.0.0", "@s/a@^1.1.0":
          version "1.2.0"
          resolved "https://r/a.tgz#abc"
          dependencies:
            b "^2.0.0"

        "c@^1 || ^2":
          version "2.0.0"
        """
        let lock = LockfileText.parse(text, style: .yarnClassic)
        let key = #""@s/a@^1.0.0", "@s/a@^1.1.0""#
        let a = lock[key] as? [String: Any]
        #expect(a?["version"] as? String == "1.2.0")
        #expect(a?["resolved"] as? String == "https://r/a.tgz#abc")
        #expect((a?["dependencies"] as? [String: Any])?["b"] as? String == "^2.0.0")
        #expect(LockfileText.descriptors(ofKey: key) == ["@s/a@^1.0.0", "@s/a@^1.1.0"])
        #expect((lock["c@^1 || ^2"] as? [String: Any])?["version"] as? String == "2.0.0")
    }

    @Test func unquotesScalars() {
        #expect(LockfileText.unquoted("'it''s'") == "it's")
        #expect(LockfileText.unquoted(#""a\"b""#) == "a\"b")
        #expect(LockfileText.unquoted("plain") == "plain")
        #expect(LockfileText.scalar("{}") as? [String: Any] != nil)
        #expect(LockfileText.parse("").isEmpty)
    }

    // MARK: - Which Tool

    @Test func choosesTheToolForAPackageJSON() throws {
        let temp = try PackageTempFolder()
        defer { temp.remove() }
        #expect(NodePackageManager.detect(in: temp.url) == nil)
        try temp.write("package.json", "{}")
        #expect(NodePackageManager.detect(in: temp.url) == .npm)
        try temp.write("yarn.lock", "")
        #expect(NodePackageManager.detect(in: temp.url) == .yarn)
        try temp.write("pnpm-lock.yaml", "")
        #expect(NodePackageManager.detect(in: temp.url) == .pnpm)
        // The packageManager field wins over the lockfiles
        try temp.write("package.json", #"{"packageManager": "npm@10.9.0"}"#)
        #expect(NodePackageManager.detect(in: temp.url) == .npm)
        try temp.write("package.json", #"{"packageManager": "bun@1.1.0"}"#)
        #expect(NodePackageManager.detect(in: temp.url) == .pnpm)
        #expect(NodePackageManager.fromField("yarn@4.5.3+sha512.abc") == .yarn)

        // Only the chosen one finds a manifest
        let backends: [PackageBackend.Type] = [NPMBackend.self, PNPMBackend.self, YarnBackend.self]
        #expect(backends.filter { $0.manifest(in: temp.url) != nil }.map { $0.identifier } == ["pnpm"])
        #expect(PNPMBackend.packageFileNames.contains("pnpm-lock.yaml"))
        #expect(YarnBackend.packageFileNames.contains("yarn.lock"))
    }

    @Test func tellsYarnVersionsApart() throws {
        let temp = try PackageTempFolder()
        defer { temp.remove() }
        try temp.write("package.json", "{}")
        #expect(!YarnBackend.isModern(folder: temp.url))
        try temp.write(".yarnrc.yml", "nodeLinker: node-modules\n")
        #expect(YarnBackend.isModern(folder: temp.url))
        try temp.write("package.json", #"{"packageManager": "yarn@1.22.22"}"#)
        #expect(!YarnBackend.isModern(folder: temp.url))
        // The lockfile wins
        try temp.write("yarn.lock", try fixtures.text("yarn-lock-berry.lock"))
        #expect(YarnBackend.isModern(folder: temp.url))
        try temp.write("yarn.lock", try fixtures.text("yarn-lock-v1.lock"))
        #expect(!YarnBackend.isModern(folder: temp.url))
    }

    @Test func pathRequirements() {
        #expect(NPMBackend.pathOfRequirement("file:../kit") == "../kit")
        #expect(NPMBackend.pathOfRequirement("link:kit") == "kit")
        #expect(NPMBackend.pathOfRequirement("portal:kit") == "kit")
        #expect(NPMBackend.pathOfRequirement("./kit") == "./kit")
        #expect(NPMBackend.pathOfRequirement("^1.2.0") == nil)
    }

    // MARK: - pnpm

    @Test func pnpm9Graph() throws {
        let graph = try Self.pnpmGraph()
        #expect(graph.rootName == "fixture-app")
        #expect(graph.isResolved)
        #expect(graph.dependencies.map(\.name) == ["chalk", "localkit", "lodash", "react", "react-dom", "@types/node", "is-number"])
        #expect(graph.dependencies.map(\.kind) == [.normal, .normal, .normal, .normal, .normal, .dev, .optional])
        #expect(graph.dependencies[1].rule == .path("./localkit"))
        #expect(graph.dependencies.map(\.resolvedID) == [
            "chalk@4.1.2", "localkit@file:localkit", "lodash@4.17.15", "react@18.3.1",
            "react-dom@18.3.1(react@18.3.1)", "@types/node@20.19.43", "is-number@7.0.0",
        ])
        let reactDOM = try #require(graph.package("react-dom@18.3.1(react@18.3.1)"))
        #expect(reactDOM.name == "react-dom")
        #expect(reactDOM.version == "18.3.1")
        #expect(reactDOM.source == .registry(nil))
        #expect(reactDOM.dependencies == ["loose-envify@1.4.0", "react@18.3.1", "scheduler@0.23.2"])
        let types = try #require(graph.package("@types/node@20.19.43"))
        #expect(types.name == "@types/node")
        #expect(types.dependencies == ["undici-types@6.21.0"])
        let local = try #require(graph.package("localkit@file:localkit"))
        #expect(local.name == "localkit")
        #expect(local.source == .path("localkit"))
        #expect(local.dependencies == ["has-flag@4.0.0"])
        #expect(graph.indirectPackages.map(\.name) == ["ansi-styles", "color-convert", "color-name", "has-flag", "js-tokens", "loose-envify", "scheduler", "supports-color", "undici-types"])
    }

    @Test func pnpm6GraphMatchesPnpm9() throws {
        let old = try Self.pnpmGraph("pnpm-lock-v6.yaml")
        let new = try Self.pnpmGraph()
        #expect(old.dependencies.map(\.resolvedID) == [
            "/chalk@4.1.2", "file:localkit", "/lodash@4.17.15", "/react@18.3.1",
            "/react-dom@18.3.1(react@18.3.1)", "/@types/node@20.19.43", "/is-number@7.0.0",
        ])
        #expect(old.packages.count == new.packages.count)
        #expect(old.package("file:localkit")?.name == "localkit")
        #expect(old.package("file:localkit")?.source == .path("localkit"))
        #expect(old.children(of: "/react-dom@18.3.1(react@18.3.1)").map(\.name) == ["loose-envify", "react", "scheduler"])
        #expect(Set(old.packages.map { "\($0.name)@\($0.version ?? "")" }) == Set(new.packages.map { "\($0.name)@\($0.version ?? "")" }))
    }

    @Test func pnpmKeysAndStoreFolders() {
        #expect(PNPMBackend.nameAndVersion(of: "@types/node@20.19.43")?.name == "@types/node")
        #expect(PNPMBackend.nameAndVersion(of: "@types/node@20.19.43")?.version == "20.19.43")
        #expect(PNPMBackend.nameAndVersion(of: "/react-dom@18.3.1(react@18.3.1)")?.name == "react-dom")
        #expect(PNPMBackend.nameAndVersion(of: "/react-dom@18.3.1(react@18.3.1)")?.version == "18.3.1")
        #expect(PNPMBackend.storeFolderName(of: "react-dom@18.3.1(react@18.3.1)") == "react-dom@18.3.1_react@18.3.1")
        #expect(PNPMBackend.storeFolderName(of: "a@1.0.0(b@2.0.0)(c@3.0.0)") == "a@1.0.0_b@2.0.0_c@3.0.0")
        #expect(PNPMBackend.storeFolderName(of: "/@types/node@20.19.43") == "@types+node@20.19.43")
        #expect(PNPMBackend.storeFolderName(of: "localkit@file:localkit") == "localkit@file+localkit")
    }

    @Test func pnpmCheckoutsAndLinks() throws {
        let temp = try PackageTempFolder()
        defer { temp.remove() }
        try temp.write("node_modules/.pnpm/react-dom@18.3.1_react@18.3.1/node_modules/react-dom/package.json", "{}")
        try temp.write("node_modules/lodash/package.json", "{}")
        try temp.write("localkit/package.json", #"{"version": "0.1.0"}"#)
        let graph = try Self.pnpmGraph(folder: temp.url)
        #expect(graph.package("react-dom@18.3.1(react@18.3.1)")?.checkout == temp.url.appendingPathComponent("node_modules/.pnpm/react-dom@18.3.1_react@18.3.1/node_modules/react-dom"))
        // A direct package falls back to its link at the top
        #expect(graph.package("lodash@4.17.15")?.checkout == temp.url.appendingPathComponent("node_modules/lodash"))
        #expect(graph.package("chalk@4.1.2")?.checkout == nil)
        #expect(graph.package("localkit@file:localkit")?.version == "0.1.0")

        // pnpm add of a folder writes link:
        let lock = "lockfileVersion: '9.0'\nimporters:\n  .:\n    dependencies:\n      kit:\n        specifier: link:kit\n        version: link:kit\n"
        let linked = PNPMBackend.graph(manifest: ["dependencies": ["kit": "link:kit"]], lock: LockfileText.parse(lock), folder: temp.url)
        #expect(linked.dependencies.first?.rule == .path("kit"))
        #expect(linked.dependencies.first?.resolvedID == "kit@link:kit")
        #expect(linked.package("kit@link:kit")?.source == .path("kit"))
    }

    @Test func pnpmWithoutALockfile() throws {
        let graph = PNPMBackend.graph(manifest: try Self.manifest(), lock: nil, folder: Self.folder)
        #expect(!graph.isResolved)
        #expect(graph.dependencies.allSatisfy { $0.resolvedID == nil })
    }

    @Test func pnpmCommands() throws {
        let backend = PNPMBackend(manifestURL: Self.folder.appendingPathComponent("package.json"), runner: FakePackageToolRunner())
        let graph = try Self.pnpmGraph()
        func run(_ change: PackageChange) throws -> [[String]] {
            try backend.command(for: change, graph: graph, manifest: "").steps.map { [$0.executable] + $0.arguments }
        }
        #expect(try run(.add(PackageSpec(name: "left-pad"), kind: .normal)) == [["pnpm", "add", "left-pad"]])
        #expect(try run(.add(PackageSpec(name: "vite", rule: .upToNextMajor("5.4.0")), kind: .dev)) == [["pnpm", "add", "vite@^5.4.0", "--save-dev"]])
        #expect(try run(.add(PackageSpec(name: "x", rule: .exact("1.0.0")), kind: .optional)) == [["pnpm", "add", "x@1.0.0", "--save-exact", "--save-optional"]])
        #expect(try run(.add(PackageSpec(name: "kit", rule: .path("../kit")), kind: .normal)) == [["pnpm", "add", "../kit"]])
        #expect(throws: PackageError.self) { try run(.add(PackageSpec(name: "x"), kind: .build)) }
        #expect(try run(.remove(name: "chalk", kind: .normal)) == [["pnpm", "remove", "chalk"]])
        #expect(try run(.update(names: [])) == [["pnpm", "update"]])
        #expect(try run(.update(names: ["chalk", "react"])) == [["pnpm", "update", "chalk", "react"]])
        #expect(try run(.changeRule(name: "@types/node", kind: .dev, rule: .requirement("^22.0.0"))) == [["pnpm", "add", "@types/node@^22.0.0", "--save-dev"]])
        #expect(throws: PackageError.self) { try run(.changeRule(name: "localkit", kind: .normal, rule: .requirement("^1"))) }
        #expect(try run(.resolve) == [["pnpm", "install"]])
    }

    // MARK: - Yarn

    @Test func yarnClassicGraph() throws {
        let graph = try Self.yarnGraph("yarn-lock-v1.lock")
        #expect(graph.isResolved)
        #expect(graph.dependencies.map(\.resolvedID) == [
            "chalk@4.1.2", "localkit@0.1.0", "lodash@4.17.15", "react@18.3.1",
            "react-dom@18.3.1", "@types/node@20.19.43", "is-number@7.0.0",
        ])
        #expect(graph.package("react-dom@18.3.1")?.dependencies == ["loose-envify@1.4.0", "scheduler@0.23.2"])
        #expect(graph.package("chalk@4.1.2")?.dependencies == ["ansi-styles@4.3.0", "supports-color@7.2.0"])
        // "js-tokens@^3.0.0 || ^4.0.0" is one descriptor
        #expect(graph.package("loose-envify@1.4.0")?.dependencies == ["js-tokens@4.0.0"])
        #expect(graph.package("localkit@0.1.0")?.source == .path("./localkit"))
        #expect(graph.package("localkit@0.1.0")?.dependencies == ["has-flag@4.0.0"])
        #expect(graph.package("lodash@4.17.15")?.source == .registry(nil))
        #expect(graph.packages.count == 16)
    }

    @Test func yarnModernGraph() throws {
        let graph = try Self.yarnGraph("yarn-lock-berry.lock")
        let local = try #require(graph.dependency(named: "localkit")?.resolvedID)
        #expect(local.hasPrefix("localkit@file:./localkit#"))
        #expect(graph.dependencies.map(\.resolvedID) == [
            "chalk@npm:4.1.2", local, "lodash@npm:4.17.15", "react@npm:18.3.1",
            "react-dom@npm:18.3.1", "@types/node@npm:20.19.43", "is-number@npm:7.0.0",
        ])
        #expect(graph.package("chalk@npm:4.1.2")?.version == "4.1.2")
        #expect(graph.package("chalk@npm:4.1.2")?.name == "chalk")
        #expect(graph.package("react-dom@npm:18.3.1")?.dependencies == ["loose-envify@npm:1.4.0", "scheduler@npm:0.23.2"])
        #expect(graph.package(local)?.source == .path("./localkit"))
        #expect(graph.package(local)?.dependencies == ["has-flag@npm:4.0.0"])
        // The workspace isn't a package
        #expect(!graph.packages.contains { $0.name == "fixture-app" })
        #expect(graph.packages.count == 16)
    }

    @Test func yarnCheckoutsOnlyForTheVersionInstalled() throws {
        let temp = try PackageTempFolder()
        defer { temp.remove() }
        try temp.write("node_modules/chalk/package.json", #"{"version": "4.1.2"}"#)
        try temp.write("node_modules/lodash/package.json", #"{"version": "4.17.21"}"#)
        try temp.write("localkit/package.json", "{}")
        let graph = try Self.yarnGraph("yarn-lock-v1.lock", folder: temp.url)
        #expect(graph.package("chalk@4.1.2")?.checkout == temp.url.appendingPathComponent("node_modules/chalk"))
        #expect(graph.package("lodash@4.17.15")?.checkout == nil)
        #expect(graph.package("react@18.3.1")?.checkout == nil)
        #expect(graph.package("localkit@0.1.0")?.checkout == temp.url.appendingPathComponent("localkit"))
        let none = YarnBackend.graph(manifest: try Self.manifest(), lockText: nil, folder: temp.url)
        #expect(!none.isResolved)
    }

    @Test func yarnCommands() throws {
        let graph = try Self.yarnGraph("yarn-lock-v1.lock")
        func run(_ change: PackageChange, modern: Bool) throws -> [[String]] {
            try YarnBackend.command(for: change, graph: graph, modern: modern).steps.map { [$0.executable] + $0.arguments }
        }
        for modern in [false, true] {
            #expect(try run(.add(PackageSpec(name: "left-pad"), kind: .normal), modern: modern) == [["yarn", "add", "left-pad"]])
            #expect(try run(.add(PackageSpec(name: "vite", rule: .upToNextMinor("5.4.0")), kind: .dev), modern: modern) == [["yarn", "add", "vite@~5.4.0", "--dev"]])
            #expect(try run(.add(PackageSpec(name: "x", rule: .exact("1.0.0")), kind: .optional), modern: modern) == [["yarn", "add", "x@1.0.0", "--exact", "--optional"]])
            #expect(try run(.remove(name: "chalk", kind: .normal), modern: modern) == [["yarn", "remove", "chalk"]])
            #expect(try run(.changeRule(name: "react", kind: .normal, rule: .requirement("^19.0.0")), modern: modern) == [["yarn", "add", "react@^19.0.0"]])
            #expect(try run(.resolve, modern: modern) == [["yarn", "install"]])
            #expect(throws: PackageError.self) { try run(.add(PackageSpec(name: "x"), kind: .build), modern: modern) }
            #expect(throws: PackageError.self) { try run(.changeRule(name: "localkit", kind: .normal, rule: .requirement("^1")), modern: modern) }
        }
        #expect(try run(.add(PackageSpec(name: "kit", rule: .path("../kit")), kind: .normal), modern: false) == [["yarn", "add", "file:../kit"]])
        #expect(try run(.add(PackageSpec(name: "kit", rule: .path("../kit")), kind: .normal), modern: true) == [["yarn", "add", "../kit"]])
        #expect(try run(.update(names: []), modern: false) == [["yarn", "upgrade"]])
        #expect(try run(.update(names: ["chalk"]), modern: false) == [["yarn", "upgrade", "chalk"]])
        #expect(try run(.update(names: []), modern: true) == [["yarn", "up", "-R", "*"]])
        #expect(try run(.update(names: ["chalk", "react"]), modern: true) == [["yarn", "up", "-R", "chalk", "react"]])
    }

    @Test func readGraphRunsNoTool() throws {
        let temp = try PackageTempFolder()
        defer { temp.remove() }
        let manifest = try temp.write("package.json", try fixtures.text("node-package.json"))
        try temp.write("pnpm-lock.yaml", try fixtures.text("pnpm-lock-v9.yaml"))
        let runner = FakePackageToolRunner()
        #expect(try PNPMBackend(manifestURL: manifest, runner: runner).readGraph().packages.count == 16)
        try temp.write("yarn.lock", try fixtures.text("yarn-lock-berry.lock"))
        #expect(try YarnBackend(manifestURL: manifest, runner: runner).readGraph().packages.count == 16)
        #expect(runner.commands.isEmpty)
        #expect(PNPMBackend(manifestURL: manifest, runner: runner).checkTool() == .missing)
        runner.installed.insert("pnpm")
        #expect(PNPMBackend(manifestURL: manifest, runner: runner).checkTool() == .available(URL(fileURLWithPath: "/usr/bin/pnpm")))
    }

    // MARK: - Audits

    @Test func pnpmAudit() throws {
        let graph = try Self.pnpmGraph()
        let advisories = try #require(PNPMBackend.parseAudit(try fixtures.object("pnpm-audit.json"), graph: graph))
        #expect(advisories.count == 5)
        #expect(Set(advisories.map(\.packageID)) == ["lodash@4.17.15"])
        let first = try #require(advisories.first)
        #expect(first.identifier == "GHSA-35jh-r3h4-6jhm")
        #expect(first.title == "Command Injection in lodash")
        #expect(first.severity == "high")
        #expect(PNPMBackend.parseAudit(["error": ["code": "x"]], graph: graph) == nil)

        let runner = FakePackageToolRunner()
        runner.installed.insert("pnpm")
        runner.answer("pnpm audit --json", with: try fixtures.data("pnpm-audit.json"), status: 1)
        let audit = PNPMBackend.audit(graph: graph, runner: runner, folder: Self.folder)
        #expect(audit.advisories.count == 5)
        #expect(audit.problem == nil)
        runner.answer("pnpm audit --json", with: Data("ERR_PNPM_AUDIT_NO_LOCKFILE".utf8), status: 1, error: "No pnpm-lock.yaml found")
        let failed = PNPMBackend.audit(graph: graph, runner: runner, folder: Self.folder)
        #expect(failed.advisories.isEmpty)
        #expect(failed.problem == "No pnpm-lock.yaml found")
    }

    @Test func yarnAudits() throws {
        let classic = try Self.yarnGraph("yarn-lock-v1.lock")
        let output = PackageToolResult(status: 12, output: try fixtures.data("yarn-audit-v1.ndjson"), errorText: "")
        let advisories = try #require(YarnBackend.parseAudit(output, modern: false, graph: classic))
        #expect(advisories.count == 5)
        #expect(Set(advisories.map(\.packageID)) == ["lodash@4.17.15"])
        #expect(advisories.first?.identifier == "GHSA-35jh-r3h4-6jhm")

        let modern = try Self.yarnGraph("yarn-lock-berry.lock")
        let modernOutput = PackageToolResult(status: 1, output: try fixtures.data("yarn-audit-berry.ndjson"), errorText: "")
        let found = try #require(YarnBackend.parseAudit(modernOutput, modern: true, graph: modern))
        #expect(found.count == 5)
        #expect(Set(found.map(\.packageID)) == ["lodash@npm:4.17.15"])
        #expect(found.first?.title == "Command Injection in lodash")
        #expect(found.first?.severity == "high")
        #expect(found.first?.url == URL(string: "https://github.com/advisories/GHSA-35jh-r3h4-6jhm"))

        // A clean audit may print nothing; a failed one with no report
        // is a problem
        #expect(YarnBackend.parseAudit(PackageToolResult(status: 0, output: Data(), errorText: ""), modern: true, graph: modern) == [])
        #expect(YarnBackend.parseAudit(PackageToolResult(status: 1, output: Data("boom".utf8), errorText: ""), modern: true, graph: modern) == nil)
        let errorOnly = Data(#"{"type":"error","data":"no lockfile"}"#.utf8)
        #expect(YarnBackend.parseAudit(PackageToolResult(status: 1, output: errorOnly, errorText: ""), modern: false, graph: classic) == nil)
        #expect(YarnBackend.auditArguments(modern: true) == ["npm", "audit", "--all", "--recursive", "--json"])
        #expect(YarnBackend.auditArguments(modern: false) == ["audit", "--json"])
    }

    @Test func checksAskTheRegistryForDirectDependencies() throws {
        let names = NodePackageChecks.checkedPackages(in: try Self.pnpmGraph()).map(\.name)
        // localkit is a folder, not from the registry
        #expect(names == ["chalk", "lodash", "react", "react-dom", "@types/node", "is-number"])
        #expect(NodePackageChecks.checkedPackages(in: try Self.yarnGraph("yarn-lock-berry.lock")).count == 6)
    }

    @Test func addPanelAndUpdatesTreatThemAsNPM() {
        for backend in [NPMBackend.self, PNPMBackend.self, YarnBackend.self] as [PackageBackend.Type] {
            #expect(backend.dependencyKinds == [.normal, .dev, .optional])
            #expect(backend.bareVersionIsExact)
            #expect(backend.searchSource() is NPMRegistrySearch)
            #expect(backend.packageFileNames.contains("package.json"))
        }
    }
}
