/**
    @file TypeScriptPackTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for the TypeScript pack's languages, servers and build.
*/

import Foundation
import Testing
import AemberLanguageKit
@testable import TypeScriptPack

/// @brief A context with nothing in it
private struct NoContext: BuildSystemContext {}

@Suite struct TypeScriptPackTests {

    let pack = TypeScriptPack()

    @Test func definesThreeLanguages() throws {
        let languages = Dictionary(uniqueKeysWithValues: pack.languages.map { ($0.id, $0) })
        #expect(Set(languages.keys) == ["javascript", "typescript", "tsx"])
        #expect(languages["javascript"]?.lspLanguageID(forExtension: "jsx") == "javascriptreact")
        #expect(languages["tsx"]?.lspLanguageID == "typescriptreact")
        #expect(languages["typescript"]?.inheritsQueriesFrom == "javascript")
        for language in languages.values {
            #expect(language.grammar?.language() != nil, "\(language.id)")
            #expect(language.queries.highlights != nil, "\(language.id)")
        }
    }

    @Test func prefersNativeTSC() throws {
        let servers = pack.languageServers
        #expect(servers.map(\.name) == ["tsc", "typescript-language-server"])
        #expect(servers[0].priority < servers[1].priority)
        #expect(servers[0].arguments == ["--lsp", "--stdio"])
        #expect(servers[0].accepts != nil)
        // A path that doesn't run isn't accepted
        #expect(!TypeScriptPack.isNativeLanguageServer(URL(fileURLWithPath: "/nonexistent/tsc")))
    }

    @Test(arguments: [
        ("Version 7.0.2", 7),
        ("Version 10.1.0\n", 10),
        ("  Version 5.9.3  ", 5),
        ("Version 7", nil),
        ("tsc 7.0.0", nil),
        ("", nil),
    ] as [(String, Int?)])
    func typeScriptMajorVersion(output: String, major: Int?) {
        #expect(TypeScriptPack.typeScriptMajorVersion(from: output) == major)
    }

    @Test func buildsWithTscAndTestsWithNpm() throws {
        let root = URL(fileURLWithPath: "/work")
        let system = TypeScriptBuildSystem()
        #expect(try system.command(for: .build, in: root, config: nil, filter: nil, outputDirectory: root, context: NoContext()).steps.map { [$0.executable] + $0.arguments } == [["npx", "tsc", "--noEmit", "--pretty", "false"]])
        #expect(try system.command(for: .test, in: root, config: nil, filter: "x", outputDirectory: root, context: NoContext()).steps.map { [$0.executable] + $0.arguments } == [["npm", "test", "--", "x"]])
    }
}
