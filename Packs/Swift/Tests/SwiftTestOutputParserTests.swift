/**
    @file SwiftTestOutputParserTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for SwiftTestOutputParser: swift test's XCTest and Swift
    Testing results captured from a real run, parameterized and skipped
    tests, issue details, and the lines it leaves for Aember.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import SwiftPack

struct SwiftTestOutputParserTests {

    @Test func swiftTestResults() throws {
        let parsed = parseOutput(try PackageFixtures().text("swift-test.txt"), with: SwiftTestOutputParser())
        let records = parsed.records
        #expect(records.diagnostics.isEmpty)
        #expect(records.passedCount == 2)
        #expect(records.failedCount == 3)

        let xctest = try #require(records.tests.first { $0.name == "TinyTests.LegacyTests/testFails" })
        #expect(xctest.outcome == .failed)
        #expect(xctest.path == "/Users/dev/Tiny/Tests/TinyTests/TinyTests.swift")
        #expect(xctest.line == 21)
        #expect(xctest.message?.hasPrefix("XCTAssertEqual failed") == true)
        #expect(xctest.duration == 0.04)

        let named = try #require(records.tests.first { $0.name == "Subtraction works" })
        #expect(named.displayName == "Subtraction works")
        #expect(named.line == 15 && named.column == 9)
        #expect(named.message == "Expectation failed: add(2, -1) == 2\nadd(2, -1) == 2 → false\nadd(2, -1) → 1")
        #expect(!records.tests.contains { $0.name.hasPrefix("run with") })
        // Build lines are Aember's
        #expect(parsed.unread.contains("Build complete! (0.70 sec)"))
    }

    @Test func parameterizedSkippedAndPlainSymbols() {
        let records = parseOutput("""
            ✔ Test parses(input:) with 3 test cases passed after 0.002 seconds.
            ➜ Test later() skipped: "Not yet"
            ✘ Test broken() recorded an issue: Something went wrong
            ✘ Test broken() failed after 0.010 seconds with 1 issue.
            """, with: SwiftTestOutputParser()).records
        #expect(records.tests.map(\.name) == ["parses(input:)", "later()", "broken()"])
        #expect(records.tests.map(\.outcome) == [.passed, .skipped, .failed])
        #expect(records.tests[1].message == "Not yet")
        #expect(records.tests[2].message == "Something went wrong")
    }

    @Test func issueDetailsFollowAsABlock() {
        let parser = SwiftTestOutputParser()
        var records = BuildRecords()
        #expect(parser.consume("✘ Test a() recorded an issue at A.swift:1:2: Bad", into: &records))
        #expect(parser.isReadingBlock)
        #expect(parser.consume("↳ detail", into: &records))
        #expect(!parser.consume("/p/a.c:1:2: warning: x", into: &records))
        #expect(!parser.isReadingBlock)
        #expect(records.tests.first?.message == "Bad\ndetail")
    }

    @Test func compilerLinesAreLeftButStrayXCTestFailuresTaken() {
        let parsed = parseOutput("/p/a.swift:1:2: error: x\n/p/b.swift:3:4: error: -[M.S t] : ", with: SwiftTestOutputParser())
        #expect(parsed.unread == ["/p/a.swift:1:2: error: x"])
    }
}
