/**
    @file CargoBackendTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for reading Cargo crates' dependencies.
    @details
    cargo metadata --no-deps for the root package: kinds, renames,
    optional and per-target dependencies, path and git sources;
    Cargo.lock's packages, dependencies written by name alone and with
    a version, and inline arrays; the graph with two versions of one
    crate, git revisions, registry sources found in Cargo's home, and
    without a lockfile; workspace members with their own dependencies,
    resolved through the shared lock, and their changes with --package;
    readGraph's command; and finding a dependency in Cargo.toml by key,
    quoted key, dotted key and table header.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import RustPack

/// The Fixtures folder beside this file
private let fixtures = PackageFixtures()

@Suite("Cargo backend")
struct CargoBackendTests {

    static let manifest = URL(fileURLWithPath: "/work/service/Cargo.toml")

    static func metadata() throws -> CargoBackend.Metadata {
        try CargoBackend.parseMetadata(fixtures.data("cargo-metadata-service.json"), manifest: manifest)
    }

    static func lock() throws -> [CargoBackend.LockPackage] {
        CargoBackend.parseLock(try fixtures.text("cargo-lock-service.lock"))
    }

    @Test func metadataReadsTheRootsDependencies() throws {
        let metadata = try Self.metadata()
        #expect(metadata.name == "service")
        #expect(metadata.roots == ["service 0.3.0"])
        // libc for two targets is one dependency
        #expect(metadata.dependencies.map(\.name) == ["serde", "tokio", "tls", "libc", "regex", "tempfile", "cc", "kit"])
        #expect(metadata.dependencies.map(\.kind) == [.normal, .normal, .optional, .normal, .normal, .dev, .build, .normal])
        #expect(metadata.dependencies[0].rule == .requirement("^1"))
        #expect(metadata.dependencies[7].rule == .path("../kit"))
        #expect(metadata.dependencies[7].location == "/work/kit")
        #expect(metadata.crateNames["tls"] == "rustls")
    }

    @Test func metadataOfARealCrate() throws {
        let metadata = try CargoBackend.parseMetadata(
            fixtures.data("cargo-metadata-appy.json"),
            manifest: URL(fileURLWithPath: "/work/appy/Cargo.toml")
        )
        #expect(metadata.name == "appy")
        #expect(metadata.dependencies.map(\.name) == ["midy", "leafy"])
        // A path dependency with a version shows the version
        #expect(metadata.dependencies[0].rule == .requirement("^0.1.0"))
        #expect(metadata.dependencies[1].rule == .path("../leafy"))
        #expect(metadata.dependencies[1].kind == .dev)
    }

    /// @brief A virtual workspace has no dependencies of its own; its
    /// members have theirs, resolved through the shared lock.
    /// (cogitae-relay's root Cargo.toml is only [workspace], its package
    /// in crates/; it once showed every crate indirect.)
    @Test func virtualWorkspaceHasMembers() throws {
        let metadata = try CargoBackend.parseMetadata(
            fixtures.data("cargo-metadata-service.json"),
            manifest: URL(fileURLWithPath: "/work/Cargo.toml")
        )
        #expect(metadata.name == "work")
        #expect(metadata.isVirtual)
        #expect(metadata.roots.isEmpty)
        #expect(metadata.dependencies.isEmpty)
        #expect(metadata.members.map(\.path) == ["service"])
        #expect(metadata.members.first?.dependencies.count == 8)
        let graph = CargoBackend.graph(metadata: metadata, lock: try Self.lock(), cargoHome: URL(fileURLWithPath: "/nonexistent"))
        #expect(graph.rootName == "work")
        #expect(graph.isWorkspaceOnly)
        let member = try #require(graph.member("service"))
        #expect(member.name == "service")
        #expect(member.manifestURL == Self.manifest)
        #expect(member.packageID == "service 0.3.0")
        #expect(member.dependencies.allSatisfy { $0.resolvedID != nil })
        #expect(graph.package("service 0.3.0")?.source == .path("service"))
        // Neither the member nor its dependencies are indirect
        #expect(graph.indirectPackages.map(\.id) == ["tokio 1.38.1"])
        let serde = try #require(member.dependencies.first?.resolvedID)
        #expect(graph.requiredBy(serde).first == "service")
    }

    @Test func membersChangeWithPackage() throws {
        let metadata = try CargoBackend.parseMetadata(
            fixtures.data("cargo-metadata-service.json"),
            manifest: URL(fileURLWithPath: "/work/Cargo.toml")
        )
        let graph = CargoBackend.graph(metadata: metadata, lock: try Self.lock(), cargoHome: URL(fileURLWithPath: "/nonexistent"))
        let backend = CargoBackend(manifestURL: URL(fileURLWithPath: "/work/Cargo.toml"), runner: FakePackageToolRunner())
        let member = try #require(graph.member("service"))
        func run(_ change: PackageChange, member: PackageMember? = nil) throws -> [[String]] {
            try backend.command(for: change, graph: graph, manifest: "", member: member).steps.map { [$0.executable] + $0.arguments }
        }
        #expect(try run(.add(PackageSpec(name: "anyhow", rule: .requirement("^1")), kind: .normal), member: member) == [["cargo", "add", "anyhow@^1", "--package", "service"]])
        #expect(try run(.remove(name: "tempfile", kind: .dev), member: member) == [["cargo", "remove", "tempfile", "--dev", "--package", "service"]])
        #expect(try run(.changeRule(name: "tls", kind: .optional, rule: .requirement("^0.23")), member: member) == [["cargo", "add", "rustls@^0.23", "--rename", "tls", "--package", "service"]])
        // The lock is shared: updating is the workspace's
        #expect(try run(.update(names: []), member: member) == [["cargo", "update"]])
        // The virtual root itself can't add
        #expect(throws: PackageError.self) { try run(.add(PackageSpec(name: "anyhow"), kind: .normal)) }
        #expect(backend.capabilities(for: graph) == [.update, .resolve])
        #expect(backend.capabilities(for: graph, member: "service") == .all)
        #expect(backend.capabilities(for: graph, member: "nowhere") == [])
    }

    @Test func workspaceMembersHaveTheirOwnDependencies() throws {
        let json = """
            {"packages": [
              {"name": "a", "version": "0.1.0", "manifest_path": "/w/a/Cargo.toml", "dependencies": [
                {"name": "serde", "req": "^1", "kind": null, "rename": null, "optional": false, "source": "registry+x"}]},
              {"name": "b", "version": "0.2.0", "manifest_path": "/w/b/Cargo.toml", "dependencies": [
                {"name": "serde", "req": "^1", "kind": null, "rename": null, "optional": false, "source": "registry+x"},
                {"name": "a", "req": "*", "kind": null, "rename": null, "optional": false, "source": null, "path": "/w/a"}]}
            ]}
            """
        let metadata = try CargoBackend.parseMetadata(Data(json.utf8), manifest: URL(fileURLWithPath: "/w/Cargo.toml"))
        #expect(metadata.roots.isEmpty)
        #expect(metadata.members.map(\.path) == ["a", "b"])
        #expect(metadata.members.map(\.id) == ["a 0.1.0", "b 0.2.0"])
        let b = try #require(metadata.members.last)
        #expect(b.dependencies.map(\.name) == ["serde", "a"])
        #expect(b.dependencies[1].rule == .path("../a"))
        let graph = CargoBackend.graph(metadata: metadata, lock: nil, cargoHome: URL(fileURLWithPath: "/nonexistent"))
        #expect(!graph.isResolved)
        #expect(graph.members.map(\.name) == ["a", "b"])
    }

    @Test func lockReadsPackages() throws {
        let lock = try Self.lock()
        #expect(lock.count == 10)
        let service = try #require(lock.first { $0.name == "service" })
        #expect(service.source == nil)
        #expect(service.dependencies.contains("tokio 1.43.0"))
        let tokio = try #require(lock.first { $0.id == "tokio 1.43.0" })
        // Written inline
        #expect(tokio.dependencies == ["libc", "serde"])
        let regex = try #require(lock.first { $0.name == "regex" })
        #expect(regex.source?.hasPrefix("git+") == true)
        let real = CargoBackend.parseLock(try fixtures.text("cargo-lock-appy.lock"))
        #expect(real.map(\.name) == ["appy", "leafy", "midy"])
        #expect(real[0].dependencies == ["leafy", "midy"])
    }

    @Test func graphResolvesVersionsAndSources() throws {
        let home = try PackageTempFolder()
        defer { home.remove() }
        try home.write("registry/src/index.crates.io-1949cf8c6b5b557f/serde-1.0.217/Cargo.toml", "")
        try home.write("git/checkouts/regex-0123456789abcdef/1a069b9/Cargo.toml", "")

        let graph = CargoBackend.graph(metadata: try Self.metadata(), lock: try Self.lock(), cargoHome: home.url)
        #expect(graph.rootName == "service")
        #expect(graph.package("service 0.3.0") == nil)
        #expect(graph.dependencies.map(\.resolvedID) == [
            "serde 1.0.217", "tokio 1.43.0", "rustls 0.23.20", "libc 0.2.169",
            "regex 1.11.1", "tempfile 3.15.0", "cc 1.2.10", "kit 0.1.0",
        ])
        #expect(graph.indirectPackages.map(\.id) == ["tokio 1.38.1"])
        #expect(graph.requiredBy("tokio 1.38.1") == ["tempfile"])
        #expect(graph.requiredBy("libc 0.2.169") == ["service", "kit", "tokio"])

        let serde = try #require(graph.package("serde 1.0.217"))
        #expect(serde.source == .registry("https://github.com/rust-lang/crates.io-index"))
        #expect(serde.checkout?.lastPathComponent == "serde-1.0.217")
        let regex = try #require(graph.package("regex 1.11.1"))
        #expect(regex.source == .git("https://github.com/rust-lang/regex"))
        #expect(regex.revision == "1a069b9232c607b34c4937122361aa075ef573fa")
        #expect(regex.checkout?.lastPathComponent == "1a069b9")
        #expect(regex.repositoryURL == URL(string: "https://github.com/rust-lang/regex"))
        let kit = try #require(graph.package("kit 0.1.0"))
        #expect(kit.source == .path("/work/kit"))
        #expect(kit.checkout == URL(fileURLWithPath: "/work/kit"))
        #expect(graph.package("tokio 1.43.0")?.checkout == nil)
    }

    @Test func graphWithoutALockfile() throws {
        let graph = CargoBackend.graph(metadata: try Self.metadata(), lock: nil, cargoHome: URL(fileURLWithPath: "/nonexistent"))
        #expect(!graph.isResolved)
        #expect(graph.packages.isEmpty)
        #expect(graph.dependencies.count == 8)
    }

    @Test func gitSources() {
        let source = CargoBackend.gitSource("git+https://github.com/a/b?branch=main#0123abc")
        #expect(source.url == "https://github.com/a/b")
        #expect(source.revision == "0123abc")
        #expect(CargoBackend.gitSource("git+https://github.com/a/b").revision == nil)
    }

    @Test func readGraphRunsMetadataOffline() throws {
        let temp = try PackageTempFolder()
        defer { temp.remove() }
        let manifest = try temp.write("Cargo.toml", "[package]\nname = \"appy\"\n")
        let json = try fixtures.text("cargo-metadata-appy.json")
            .replacingOccurrences(of: "/work/appy", with: temp.url.path)
        let runner = FakePackageToolRunner()
        runner.answer("cargo metadata --format-version 1 --no-deps --offline", with: Data(json.utf8))
        let backend = CargoBackend(manifestURL: manifest, runner: runner)
        let unlocked = try backend.readGraph()
        #expect(unlocked.rootName == "appy")
        #expect(!unlocked.isResolved)
        try temp.write("Cargo.lock", try fixtures.text("cargo-lock-appy.lock"))
        let locked = try backend.readGraph()
        #expect(locked.isResolved)
        #expect(locked.dependencies.map(\.resolvedID) == ["midy 0.1.0", "leafy 0.1.0"])
        #expect(locked.children(of: "midy 0.1.0").map(\.id) == ["leafy 0.1.0"])
    }

    static let toml = """
        [package]
        name = "service"

        [dependencies]
        serde = { version = "1", features = ["derive"] }
        tokio.version = "1.40"
        "tls" = { package = "rustls", version = "0.23", optional = true }

        [target.'cfg(unix)'.dependencies]
        libc = "0.2"

        [dev-dependencies]
        tempfile = "3"

        [build-dependencies.cc]
        version = "1.0"
        """

    @Test func declarationInCargoToml() {
        func line(_ name: String, _ kind: DependencyKind = .normal) -> Int? {
            CargoBackend.declarationLine(of: PackageDependency(name: name, kind: kind), in: Self.toml)
        }
        #expect(line("serde") == 5)
        #expect(line("tokio") == 6)
        #expect(line("tls", .optional) == 7)
        #expect(line("libc") == 10)
        #expect(line("tempfile", .dev) == 13)
        #expect(line("cc", .build) == 15)
        #expect(line("tempfile") == nil)
        #expect(line("missing") == nil)
    }
}
