/**
    @file CFamilyPackTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Tests for the C Family pack's languages, clangd and build systems.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import CFamilyPack

@Suite struct CFamilyPackTests {

    let pack = CFamilyPack()

    @Test func definesCAndCpp() throws {
        let languages = Dictionary(uniqueKeysWithValues: pack.languages.map { ($0.id, $0) })
        let c = try #require(languages["c"])
        let cpp = try #require(languages["cpp"])
        #expect(c.lspLanguageID(forExtension: "m") == "objective-c")
        #expect(c.lspLanguageID(forExtension: "h") == "c")
        #expect(cpp.lspLanguageID(forExtension: "mm") == "objective-cpp")
        #expect(cpp.extensions.contains("hxx"))
        #expect(c.grammar?.language() != nil)
        #expect(cpp.grammar?.language() != nil)
    }

    @Test func clangdReadsTheProjectsDatabase() throws {
        let clangd = try #require(pack.languageServers.first)
        #expect(clangd.serverKey == "c-family")
        #expect(Set(clangd.languages) == ["c", "cpp", "objective-c", "objective-cpp"])
        #expect(clangd.restartTriggers == [.compilationDatabaseChanged])
        #expect(clangd.arguments(for: URL(fileURLWithPath: "/work")) == ["--background-index", "--clang-tidy", "--compile-commands-dir=/work/.aember"])

        // Starting touches compile_commands.json, when there is one
        let fixture = try BuildSystemFixture()
        let database = try fixture.write(".aember/compile_commands.json", "[]")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: database.path)
        clangd.prepare?(fixture.root)
        let date = try FileManager.default.attributesOfItem(atPath: database.path)[.modificationDate] as? Date
        #expect((date ?? .distantPast) > Date(timeIntervalSince1970: 0))
    }

    @Test func detectsCMakeNinjaAndMakeInOrder() throws {
        #expect(pack.buildSystems.map(\.identifier) == ["cmake", "ninja", "make"])
        #expect(pack.buildSystems.map(\.priority) == [300, 400, 600])
    }
}
