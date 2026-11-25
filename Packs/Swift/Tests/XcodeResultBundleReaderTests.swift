/**
    @file XcodeResultBundleReaderTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for XcodeResultBundleReader: xcresulttool's build and
    test JSON captured from a real run, with 0-based places made 1-based
    and tests named Target/identifier; reading a bundle through a
    stand-in tool; and input that isn't a report.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import SwiftPack

/// @brief The stand-in tool's calls
private final class Calls: @unchecked Sendable {
    private(set) var all: [[String]] = []
    func append(_ call: [String]) { all.append(call) }
}

struct XcodeResultBundleReaderTests {

    private let fixtures = PackageFixtures()

    /// @brief Build results: errors then warnings, places 1-based.
    @Test func xcodeBuildResults() throws {
        let diagnostics = try #require(XcodeResultBundleReader.diagnostics(
            fromBuildResults: try fixtures.data("xcresult-build.json")
        ))
        #expect(diagnostics.map(\.severity) == [.error, .warning, .warning])
        #expect(diagnostics[0].path == "/Users/dev/Tiny/Sources/Tiny/Broken.swift")
        #expect(diagnostics[0].line == 3)
        #expect(diagnostics[0].column == 12)
        #expect(diagnostics[1].line == 2 && diagnostics[1].column == 9)
        #expect(diagnostics[2].path == nil)
        #expect(diagnostics[2].message == "A warning without a place")
    }

    /// @brief Test results: every case, named Target/identifier, with
    /// display names, failure messages, places and durations.
    @Test func xcodeTestResults() throws {
        let tests = try #require(XcodeResultBundleReader.tests(
            fromTestResults: try fixtures.data("xcresult-tests.json")
        ))
        #expect(tests.map(\.name) == [
            "TinyTests/addsNumbers()",
            "TinyTests/failsOnPurpose()",
            "TinyTests/LegacyTests/testFails()",
            "TinyTests/LegacyTests/testPasses()",
            "TinyTests/Arithmetic/subtracts()"
        ])
        #expect(tests.map(\.outcome) == [.passed, .failed, .failed, .passed, .failed])
        #expect(tests.map(\.displayName) == [nil, nil, nil, nil, "Subtraction works"])
        #expect(tests[1].line == 10)
        #expect(tests[1].message == "Expectation failed: add(1, 2) == 4\nadd(1, 2) → 3")
        #expect(tests[2].path == "/Users/dev/Tiny/Tests/TinyTests/TinyTests.swift")
        #expect(tests[2].duration == 0.356)
    }

    /// @brief A bundle is read with build-results and test-results.
    @Test func readsBundleThroughTool() throws {
        let build = try fixtures.data("xcresult-build.json")
        let calls = Calls()
        let result = XcodeResultBundleReader.read(
            bundle: URL(fileURLWithPath: "/tmp/R.xcresult")
        ) { arguments in
            calls.append(arguments)
            return arguments[1] == "build-results" ? build : nil
        }
        #expect(result.diagnostics?.count == 3)
        #expect(result.tests == nil)
        #expect(calls.all.map { $0.prefix(3).joined(separator: " ") } == [
            "get build-results --path", "get test-results tests"
        ])
    }

    /// @brief Input that isn't a report reads as nothing.
    @Test func notReports() {
        #expect(XcodeResultBundleReader.diagnostics(fromBuildResults: Data("{}".utf8)) == nil)
        #expect(XcodeResultBundleReader.tests(fromTestResults: Data("[1]".utf8)) == nil)
    }

    /// @brief A source URL's fragment gives 0-based places.
    @Test func sourceURLPlace() throws {
        let place = try #require(XcodeResultBundleReader.place(
            of: "file:///a/My%20File.swift#StartingColumnNumber=0&StartingLineNumber=9"
        ))
        #expect(place.path == "/a/My File.swift")
        #expect(place.line == 10)
        #expect(place.column == 1)
        #expect(XcodeResultBundleReader.place(of: "https://x") == nil)
    }

    @Test func thePackReadsTheXcresultFormat() {
        #expect(XcodeResultBundleReader.reader.identifier == "xcresult")
    }
}
