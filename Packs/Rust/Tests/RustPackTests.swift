/**
    @file RustPackTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for the Rust pack's contributions and Cargo's commands.
*/

import Foundation
import Testing
import AemberLanguageKit
@testable import RustPack

/// @brief A context with nothing in it
private struct NoContext: BuildSystemContext {}

@Suite struct RustPackTests {

    let pack = RustPack()

    @Test func definesRust() throws {
        let rust = try #require(pack.languages.first)
        #expect(rust.extensions == ["rs"])
        #expect(rust.grammar?.language() != nil)
        #expect(rust.docComment == "///")
        let server = try #require(pack.languageServers.first)
        #expect(server.name == "rust-analyzer")
        #expect(server.searchDirectories == ["~/.cargo/bin"])
        #expect(pack.packageBackends.map { $0.identifier } == ["cargo"])
        #expect(CargoBackend.packageFileNames == ["Cargo.toml", "Cargo.lock"])
        #expect(CargoBackend.searchSource() is CratesIOSearch)
    }

    @Test func cargoBuildsAndTests() throws {
        let root = URL(fileURLWithPath: "/work")
        let build = try CargoBuildSystem().command(for: .build, in: root, config: nil, filter: nil, outputDirectory: root, context: NoContext())
        #expect(build.steps.map { [$0.executable] + $0.arguments } == [["cargo", "build", "--message-format=json"]])
        #expect(build.environmentIdentifier == "cargo")
        let test = try CargoBuildSystem().command(for: .test, in: root, config: nil, filter: "adds", outputDirectory: root, context: NoContext())
        #expect(test.steps.map { [$0.executable] + $0.arguments } == [["cargo", "test", "adds"]])
    }
}
