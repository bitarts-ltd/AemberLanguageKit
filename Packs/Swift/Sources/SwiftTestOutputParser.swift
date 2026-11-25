/**
    @file SwiftTestOutputParser.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Reads XCTest's and Swift Testing's console output.
    @details
    - Swift Testing's event lines: a symbol (an SF Symbol in a
      terminal, ✔ ✘ and the like elsewhere), then `Test name()
      passed|failed after ...`, `... skipped`, or `... recorded an
      issue at File:12:5: message` with up to four detail lines after
      it.
    - XCTest's `Test Case '-[Suite test]' passed|failed (...)` and its
      failure lines, `path:line: error: -[Suite test] : message`.
    - `swift build`'s and xcodebuild's summaries ("Fatal error: could
      not build"), which repeat the errors and are dropped.

    Test names are the ones the test command's filter takes: Swift
    Testing's function names (a display name is kept beside it) and
    XCTest's `Module.Class/method`.
*/

import Foundation
import AemberLanguageKit

// l10n-exempt-file: matches the English output of XCTest and Swift Testing

/// @brief Parses XCTest's and Swift Testing's lines
final class SwiftTestOutputParser: BuildOutputParser {

    /// @brief The Swift Testing test whose issue's detail lines follow
    private var issueTest: String?

    /// @brief Detail lines added to the issue so far
    private var issueDetails = 0

    /// @brief The most detail lines kept under an issue
    private static let maxIssueDetails = 4

    var isReadingBlock: Bool {
        issueTest != nil
    }

    func consume(_ line: String, into records: inout BuildRecords) -> Bool {
        if let test = issueTest {
            if let detail = Self.detail(line) {
                if issueDetails < Self.maxIssueDetails {
                    records.appendToMessage(detail, ofTest: test)
                    issueDetails += 1
                }
                return true
            }
            issueTest = nil
        }
        if parseXCTest(line, into: &records) || parseSwiftTesting(line, into: &records) {
            return true
        }
        // An XCTest failure line the pattern above didn't read looks
        // like a compiler error; it isn't one
        if let groups = Self.strayFailurePattern.match(line), groups[0] != nil {
            return true
        }
        return Self.summaryPattern.match(line) != nil
    }

    func finish(into records: inout BuildRecords) {
        issueTest = nil
    }

    // MARK: - XCTest

    /// @brief Parses XCTest's result and failure lines.
    /// @return Whether the line was one
    private func parseXCTest(_ line: String, into records: inout BuildRecords) -> Bool {
        if let groups = Self.xctestFailurePattern.match(line) {
            records.record(BuildTestResult(name: groups[2]! + "/" + groups[3]!, path: groups[0], line: groups[1].flatMap { Int($0) }, outcome: .failed, message: groups[4]))
            return true
        }
        guard let groups = Self.xctestResultPattern.match(line) else {
            return false
        }
        let outcome: BuildTestOutcome
        switch groups[2]! {
        case "passed": outcome = .passed
        case "failed": outcome = .failed
        default: outcome = .skipped
        }
        records.record(BuildTestResult(name: groups[0]! + "/" + groups[1]!, outcome: outcome, duration: groups[3].flatMap { TimeInterval($0) }))
        return true
    }

    // MARK: - Swift Testing

    /// @brief Parses Swift Testing's event lines.
    /// @return Whether the line was one
    private func parseSwiftTesting(_ line: String, into records: inout BuildRecords) -> Bool {
        guard let event = Self.event(line) else { return false }

        if let groups = Self.issuePattern.match(event) {
            let (name, display) = Self.testName(groups[0]!)
            records.record(BuildTestResult(name: name, displayName: display, path: groups[1], line: groups[2].flatMap { Int($0) }, column: groups[3].flatMap { Int($0) }, outcome: .failed, message: groups[4]))
            issueTest = name
            issueDetails = 0
            return true
        }
        if let groups = Self.endedPattern.match(event) {
            let (name, display) = Self.testName(groups[0]!)
            records.record(BuildTestResult(name: name, displayName: display, outcome: groups[1] == "passed" ? .passed : .failed, duration: groups[2].flatMap { TimeInterval($0) }))
            return true
        }
        if let groups = Self.skippedPattern.match(event) {
            let (name, display) = Self.testName(groups[0]!)
            records.record(BuildTestResult(name: name, displayName: display, outcome: .skipped, message: groups[1]))
            return true
        }
        return false
    }

    /// @brief A Swift Testing line's text after its symbol, if the line
    /// is one.
    private static func event(_ line: String) -> String? {
        guard let first = line.unicodeScalars.first, first.value > 127 else {
            return nil
        }
        let rest = line.unicodeScalars.dropFirst()
        guard rest.first == " " else { return nil }
        return String(String.UnicodeScalarView(rest)).trimmingCharacters(in: .whitespaces)
    }

    /// @brief A detail line under an issue, if line is one: a symbol
    /// line that isn't a test or suite event.
    private static func detail(_ line: String) -> String? {
        guard let event = event(line), !event.hasPrefix("Test "), !event.hasPrefix("Suite ") else {
            return nil
        }
        return event
    }

    /// @brief A test's name and display name.
    /// @detail
    /// A test with a display name is printed as that name, quoted; a
    /// parameterized one with "with N test cases" after it.
    /// @param printed The name as printed
    /// @return The name, and the display name when it was quoted
    private static func testName(_ printed: String) -> (String, String?) {
        var name = printed
        if let range = name.range(of: #" with \d+ test cases?$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
            let display = String(name.dropFirst().dropLast())
            return (display, display)
        }
        return (name, nil)
    }

    // MARK: - Patterns

    private static let strayFailurePattern = LinePattern(#"^(\S[^:]*):\d+:(?:\d+:)?\s+(?:fatal error|error|warning|note|remark):\s*-\[.*\] : "#)
    private static let summaryPattern = LinePattern(#"^(?:[\w.+-]+: )?(?:fatal error|error|warning)(?:\[\w+\])?: .*(?:fatalError|Fatal error: could not build)"#)
    private static let xctestFailurePattern = LinePattern(#"^(\S.*?):(\d+): error: -\[(\S+) (\S+)\] : (.*)$"#)
    private static let xctestResultPattern = LinePattern(#"^Test Case '(?:-\[)?([^\s\]']+?)[ .]([^\s\]'.]+)\]?' (passed|failed|skipped) \(([\d.]+) seconds\)"#)
    private static let issuePattern = LinePattern(#"^Test (?!run with )(.+?) recorded an issue(?: at (\S+?):(\d+):(\d+))?: (.*)$"#)
    private static let endedPattern = LinePattern(#"^Test (?!run with )(.+?) (passed|failed) after ([\d.]+) seconds"#)
    private static let skippedPattern = LinePattern(#"^Test (?!run with )(.+?) skipped(?:: "?(.*?)"?)?\.?$"#)
}
