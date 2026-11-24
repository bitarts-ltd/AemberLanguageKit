/**
    @file PHPPackTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Tests for the PHP pack's contributions.
    @details
    Aember's tests load the built pack and check it through Aember's
    lookups; these check the pack's own code.
*/

import Foundation
import Testing
import AemberLanguageKit
@testable import PHPPack

@Suite struct PHPPackTests {

    let pack = PHPPack()

    @Test func definesPHP() throws {
        #expect(pack.manifest.id == "php")
        let php = try #require(pack.languages.first)
        #expect(php.id == "php")
        #expect(php.extensions == ["php", "phtml"])
        #expect(php.lspLanguageID(forExtension: "phtml") == "php")
        #expect(php.grammar?.language() != nil)
        #expect(php.queries.highlights?.contains("@keyword") == true)
        #expect(php.docComment == "/**")
    }

    @Test func runsIntelephense() throws {
        let server = try #require(pack.languageServers.first)
        #expect(server.name == "intelephense")
        #expect(server.arguments(for: URL(fileURLWithPath: "/p")) == ["--stdio"])
        #expect(server.searchDirectories.contains { $0.hasSuffix("/.npm-global/bin") })
    }

    @Test func detectsComposerProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try #require(pack.buildSystems.first)
        #expect(provider.identifier == "php")
        #expect(provider.detect(root) == nil)
        try Data("{}".utf8).write(to: root.appendingPathComponent("composer.json"))
        let system = try #require(provider.detect(root))
        #expect(throws: BuildCommandError.unsupported(action: .test, system: "PHP/Composer")) {
            try system.command(for: .test, in: root, config: nil, filter: nil, outputDirectory: root, context: NoContext())
        }
    }
}

/// @brief A context with nothing in it
private struct NoContext: BuildSystemContext {}
