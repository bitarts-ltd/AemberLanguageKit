/**
    @file CratesIOSearchTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for searching crates.io.
    @details
    crates.io's answers, saved from the API, parsed into results and
    versions (yanked ones left out), and the source asking a stub
    server.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import RustPack

/// The Fixtures folder beside this file
private let fixtures = PackageFixtures()

@Suite("crates.io search")
struct CratesIOSearchTests {

    // MARK: - crates.io

    @Test func cratesSearchParses() throws {
        let results = try CratesIOSearch.parseSearch(fixtures.object("crates-search.json"), host: "crates.io")
        #expect(results.map(\.name) == ["serde", "serde-saphyr", "clickhouse"])
        #expect(results[0].location == "serde")
        #expect(results[0].summary == "A generic serialization/deserialization framework")
        // The newest stable version, not the release candidate
        #expect(results[1].latestVersion == "2.2.0")
        #expect(throws: PackageSearchError.unreadable("crates.io")) {
            try CratesIOSearch.parseSearch(["errors": []], host: "crates.io")
        }
    }

    @Test func crateVersionsLeaveOutYanked() throws {
        let saved = try CratesIOSearch.parseVersions(fixtures.object("crates-versions.json"), host: "crates.io")
        #expect(saved.first == "1.0.19")
        #expect(saved.count == 12)
        let versions = try CratesIOSearch.parseVersions([
            "versions": [
                ["num": "0.9.0", "yanked": false],
                ["num": "1.0.0", "yanked": true],
                ["num": "0.10.0", "yanked": false],
            ],
        ], host: "crates.io")
        #expect(versions == ["0.10.0", "0.9.0"])
    }

    // MARK: - Against a Server

    @Test func cratesSourceAsksTheAPI() async throws {
        let service = StubHTTPService()
        service.on("/api/v1/crates") { _ in .json(200, (try? fixtures.object("crates-search.json")) ?? [:]) }
        service.on("/api/v1/crates/serde/versions") { _ in .json(200, ["versions": [["num": "1.0.1", "yanked": false]]]) }
        let source = CratesIOSearch(baseURL: URL(string: "https://crates.test/api/v1")!, http: PackageHTTP(session: service.session))
        let results = try await source.search("serde json")
        #expect(results.count == 3)
        let request = try #require(service.requests(to: "/api/v1/crates").first)
        #expect(request.url?.query?.contains("q=serde%20json") == true)
        #expect(request.headers["User-Agent"]?.hasPrefix("Aember/") == true)
        let details = try await source.details(of: results[0])
        #expect(details.versions == ["1.0.1"])
        #expect(details.summary == results[0].summary)
    }
}
