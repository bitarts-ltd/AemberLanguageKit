/**
    @file ExamplePackTests.swift
    @brief Tests for the example pack, run by `swift test`.
    @details
    Test a pack's own logic here: its parsers, the commands its build
    systems make, its checks. Aember's loading of the pack is checked
    by Scripts/check-pack.sh on the built file.
*/

import Foundation
import Testing
import AemberLanguageKit
@testable import ExamplePack

struct ExamplePackTests {

    @Test func theManifestMatchesTheInfoPlist() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let pack = ExamplePack()
        #expect(pack.manifest.id == plist[LanguagePackInfoKey.identifier] as? String)
        #expect(pack.manifest.version.description == plist[LanguagePackInfoKey.version] as? String)
        let api = try #require(LanguagePackVersion(plist[LanguagePackInfoKey.apiVersion] as? String ?? ""))
        #expect(LanguagePackAPI.isCompatible(api))
    }

    @Test func examplesAreItsFiles() {
        let language = ExamplePack().languages.first
        #expect(language?.extensions == ["example"])
        #expect(language?.lineComment == "#")
    }
}
