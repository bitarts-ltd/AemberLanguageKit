/**
    @file CargoOutputParserTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for CargoOutputParser, against output captured from real
    builds: cargo's JSON messages, cargo test's results with panics, and
    rustc's human-readable output, whose messages Aember reads and whose
    places and summaries the parser takes.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import RustPack

struct CargoOutputParserTests {

    private let fixtures = PackageFixtures()

    @Test func cargoJSONMessagesWithNotes() throws {
        let parsed = parseOutput(try fixtures.text("cargo-json.txt"), with: CargoOutputParser())
        #expect(parsed.records.errorCount == 1)
        #expect(parsed.records.warningCount == 1)
        let error = try #require(parsed.records.diagnostics.first)
        #expect(error.path == "src/main.rs")
        #expect(error.line == 4 && error.column == 18)
        #expect(error.notes.map(\.message) == ["expected `i32`, found `&str`"])
    }

    @Test func cargoTestResultsAndPanics() throws {
        let records = parseOutput(try fixtures.text("cargo-test.txt"), with: CargoOutputParser()).records
        #expect(records.tests.map(\.name) == ["tests::adds", "tests::subtracts", "tests::slow"])
        #expect(records.tests.map(\.outcome) == [.passed, .failed, .skipped])
        let failed = records.tests[1]
        #expect(failed.path == "src/lib.rs")
        #expect(failed.line == 20 && failed.column == 9)
        #expect(failed.message == "assertion `left == right` failed")
    }

    @Test func rustcPlacesAndSummariesAreTaken() throws {
        let parsed = parseOutput(try fixtures.text("rustc-human.txt"), with: CargoOutputParser())
        // The messages are left for Aember; their places and the
        // summaries are the parser's
        #expect(parsed.unread.contains { $0.hasPrefix("error[E0425]") })
        #expect(!parsed.unread.contains { $0.contains("-->") })
        #expect(!parsed.unread.contains { $0.contains("aborting due to") || $0.contains("could not compile") })
    }

    @Test func otherLinesAreLeft() {
        let parsed = parseOutput("/p/a.c:1:2: warning: unused\nTest Case '-[M.S testA]' passed (0.001 seconds).", with: CargoOutputParser())
        #expect(parsed.unread.count == 2)
    }
}
