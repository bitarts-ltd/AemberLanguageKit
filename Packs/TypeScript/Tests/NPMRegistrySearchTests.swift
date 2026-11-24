/**
    @file NPMRegistrySearchTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Tests for searching the npm registry.
    @details
    The registry's answers, saved, parsed into results and versions
    (the latest tag first), and the source asking a stub server for a
    package's abbreviated metadata.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import TypeScriptPack

/// The Fixtures folder beside this file
private let fixtures = PackageFixtures()

@Suite("npm registry search")
struct NPMRegistrySearchTests {

    // MARK: - npm

    @Test func npmSearchParses() throws {
        let results = try NPMRegistrySearch.parseSearch(fixtures.object("npm-search.json"), host: "registry.npmjs.org")
        #expect(results.map(\.name) == ["pad-left", "@stdlib/string-left-pad", "lpad"])
        #expect(results[1].latestVersion == "0.2.3")
        #expect(results[2].summary == "Left-pad each line in a string")
    }

    @Test func npmVersionsPutLatestFirst() throws {
        let saved = try NPMRegistrySearch.parseVersions(fixtures.object("npm-abbrev.json"), host: "registry.npmjs.org")
        #expect(saved.first == "1.3.0")
        #expect(saved.count == 15)
        // A newer pre-release stays after the latest tag
        let versions = try NPMRegistrySearch.parseVersions([
            "dist-tags": ["latest": "2.0.0"],
            "versions": ["1.0.0": [:], "2.0.0": [:], "3.0.0-beta.1": [:]],
        ], host: "registry.npmjs.org")
        #expect(versions == ["2.0.0", "3.0.0-beta.1", "1.0.0"])
    }

    // MARK: - Against a Server

    @Test func npmSourceAsksForAbbreviatedMetadata() async throws {
        let service = StubHTTPService()
        service.on("/@types/node") { _ in .json(200, ["dist-tags": ["latest": "1.0.0"], "versions": ["1.0.0": [:]]]) }
        let source = NPMRegistrySearch(baseURL: URL(string: "https://npm.test")!, http: PackageHTTP(session: service.session))
        let details = try await source.details(of: PackageSearchResult(name: "@types/node", location: "@types/node"))
        #expect(details.versions == ["1.0.0"])
        let request = try #require(service.requests(to: "/@types/node").first)
        #expect(request.url?.absoluteString == "https://npm.test/@types%2Fnode")
        #expect(request.headers["Accept"] == "application/vnd.npm.install-v1+json")
    }
}
