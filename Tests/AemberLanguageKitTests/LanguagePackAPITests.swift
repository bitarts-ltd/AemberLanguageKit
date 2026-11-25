/**
    @file LanguagePackAPITests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief
    Tests for versions, API compatibility, localized text and the entry point.
*/

import Foundation
import Testing
@testable import AemberLanguageKit

/// @brief A pack with only a manifest.
private final class EmptyPack: LanguagePack {
    let manifest = LanguagePackManifest(id: "empty", name: "Empty", version: LanguagePackVersion(1, 2, 3), author: "BitArts")
}

@Suite struct LanguagePackVersionTests {

    @Test func parsesOneToThreeParts() {
        #expect(LanguagePackVersion("1") == LanguagePackVersion(1, 0, 0))
        #expect(LanguagePackVersion("1.2") == LanguagePackVersion(1, 2, 0))
        #expect(LanguagePackVersion(" 1.2.3 ") == LanguagePackVersion(1, 2, 3))
    }

    @Test func refusesWhatIsNotAVersion() {
        #expect(LanguagePackVersion("") == nil)
        #expect(LanguagePackVersion("1.2.3.4") == nil)
        #expect(LanguagePackVersion("1.x") == nil)
        #expect(LanguagePackVersion("1..2") == nil)
        #expect(LanguagePackVersion("-1") == nil)
    }

    @Test func comparesNumerically() {
        #expect(LanguagePackVersion(1, 10) > LanguagePackVersion(1, 9))
        #expect(LanguagePackVersion(2, 0) > LanguagePackVersion(1, 99, 99))
        #expect(LanguagePackVersion(1, 2, 3).description == "1.2.3")
    }
}

@Suite struct LanguagePackAPICompatibilityTests {

    @Test func zeroMajorNeedsTheSameMinor() {
        let host = LanguagePackVersion(0, 2)
        #expect(LanguagePackAPI.isCompatible(LanguagePackVersion(0, 2, 5), with: host))
        #expect(!LanguagePackAPI.isCompatible(LanguagePackVersion(0, 1), with: host))
        #expect(!LanguagePackAPI.isCompatible(LanguagePackVersion(0, 3), with: host))
    }

    @Test func laterMajorsTakeOlderMinors() {
        let host = LanguagePackVersion(1, 3)
        #expect(LanguagePackAPI.isCompatible(LanguagePackVersion(1, 0), with: host))
        #expect(LanguagePackAPI.isCompatible(LanguagePackVersion(1, 3), with: host))
        #expect(!LanguagePackAPI.isCompatible(LanguagePackVersion(1, 4), with: host))
        #expect(!LanguagePackAPI.isCompatible(LanguagePackVersion(2, 0), with: host))
        #expect(!LanguagePackAPI.isCompatible(LanguagePackVersion(0, 3), with: host))
    }
}

@Suite struct LocalizedTextTests {

    let text = LocalizedText("Color", translations: ["de": "Farbe", "pt-BR": "Cor"])

    @Test func picksTheFirstPreferredLanguageItHas() {
        #expect(text.resolved(for: ["ja", "de"]) == "Farbe")
        #expect(text.resolved(for: ["pt-BR"]) == "Cor")
    }

    @Test func fallsBackFromRegionToLanguage() {
        #expect(text.resolved(for: ["de-AT"]) == "Farbe")
        #expect(text.resolved(for: ["de_CH"]) == "Farbe")
    }

    @Test func englishWinsWhenPreferredAndIsTheLastResort() {
        #expect(text.resolved(for: ["en-GB", "de"]) == "Color")
        #expect(text.resolved(for: ["ja", "fr"]) == "Color")
        #expect(text.resolved(for: []) == "Color")
    }
}

@Suite struct LanguagePackEntryTests {

    @Test func exportedPackComesBack() throws {
        let pointer = LanguagePackAPI.export(EmptyPack())
        let pack = try #require(LanguagePackAPI.take(pointer))
        #expect(pack.manifest.id == "empty")
        #expect(pack.languages.isEmpty)
        #expect(pack.languageServers.isEmpty)
    }

    @Test func otherObjectsAreNotPacks() {
        let pointer = Unmanaged.passRetained(NSObject()).toOpaque()
        #expect(LanguagePackAPI.take(pointer) == nil)
    }

    @Test func contributionIDsReadAsPaths() {
        let id = ContributionID(pack: "swift", kind: .buildSystem, id: "xcode")
        #expect(id.description == "swift/buildSystem/xcode")
    }

    @Test func lspIDsPerExtensionOverrideTheLanguages() {
        let language = LanguageDefinition(id: "cpp", displayName: "C++", extensions: ["cpp", "mm"], lspLanguageID: "cpp", lspLanguageIDsByExtension: ["mm": "objective-cpp"])
        #expect(language.lspLanguageID(forExtension: "MM") == "objective-cpp")
        #expect(language.lspLanguageID(forExtension: "cpp") == "cpp")
    }
}
