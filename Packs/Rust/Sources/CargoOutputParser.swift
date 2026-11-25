/**
    @file CargoOutputParser.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Reads rustc's and Cargo's console output.
    @details
    - cargo's `--message-format=json` lines: compiler messages, their
      primary span giving the place and their children the notes;
      other JSON lines are taken and dropped.
    - rustc's ` --> path:line:column` line, the place of the
      diagnostic above it (Aember reads `error[E0308]: message` itself,
      as a diagnostic without a place).
    - `cargo test`'s `test name ... ok|FAILED|ignored`, and a panic's
      `thread 'name' panicked at path:line:column:` with its message
      on the next line (or the older one-line form).
    - rustc's and Cargo's summaries ("could not compile", "aborting
      due to"), which repeat the errors and are dropped.
*/

import Foundation
import AemberLanguageKit

// l10n-exempt-file: matches the English output of rustc and Cargo

/// @brief Parses Cargo's and rustc's lines
final class CargoOutputParser: BuildOutputParser {

    /// @brief The test whose panic message is on the next line
    private var panickedTest: String?

    var isReadingBlock: Bool {
        panickedTest != nil
    }

    func consume(_ line: String, into records: inout BuildRecords) -> Bool {
        if let test = panickedTest {
            panickedTest = nil
            let message = line.trimmingCharacters(in: .whitespaces)
            if !message.isEmpty && !message.hasPrefix("note:") {
                records.record(BuildTestResult(name: test, outcome: .failed, message: message))
                return true
            }
        }
        if line.hasPrefix("{\"reason\":") {
            parseMessage(line, into: &records)
            return true
        }
        if parseTest(line, into: &records) {
            return true
        }
        if let groups = Self.placePattern.match(line) {
            records.placeLast(path: groups[0]!, line: Int(groups[1]!) ?? 1, column: Int(groups[2]!))
            return true
        }
        // A summary of the errors above it
        return Self.summaryPattern.match(line) != nil
    }

    /// @brief Whether a message only sums up others.
    /// @param message A message
    /// @return True for rustc's and Cargo's summaries
    static func isSummary(_ message: String) -> Bool {
        message.contains("could not compile") || message.contains("aborting due to")
    }

    /// @brief Parses a cargo `--message-format=json` line.
    /// @param line The JSON line
    /// @param records What the run found
    /// @return None
    private func parseMessage(_ line: String, into records: inout BuildRecords) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["reason"] as? String == "compiler-message",
              let message = object["message"] as? [String: Any],
              let text = message["message"] as? String,
              let level = message["level"] as? String
        else {
            return
        }
        let severity: BuildSeverity
        switch level {
        case "error", "error: internal compiler error":
            severity = .error
        case "warning":
            severity = .warning
        default:
            return
        }
        if Self.isSummary(text) || Self.generatedWarnings.match(text) != nil {
            return
        }
        let span = Self.primarySpan(message)
        var diagnostic = BuildDiagnostic(path: span?["file_name"] as? String, line: span?["line_start"] as? Int, column: span?["column_start"] as? Int, severity: severity, message: text)
        for child in message["children"] as? [[String: Any]] ?? [] {
            guard let childText = child["message"] as? String else {
                continue
            }
            let childSpan = Self.primarySpan(child)
            diagnostic.notes.append(BuildNote(path: childSpan?["file_name"] as? String, line: childSpan?["line_start"] as? Int, column: childSpan?["column_start"] as? Int, message: childText))
        }
        records.add(diagnostic)
    }

    /// @brief A message's primary span, else its first.
    private static func primarySpan(_ message: [String: Any]) -> [String: Any]? {
        let spans = message["spans"] as? [[String: Any]] ?? []
        return spans.first { $0["is_primary"] as? Bool == true } ?? spans.first
    }

    /// @brief Parses `cargo test`'s result and panic lines.
    /// @return Whether the line was one
    private func parseTest(_ line: String, into records: inout BuildRecords) -> Bool {
        if let groups = Self.testPattern.match(line) {
            let outcome: BuildTestOutcome
            switch groups[1]! {
            case "ok": outcome = .passed
            case "FAILED": outcome = .failed
            default: outcome = .skipped
            }
            records.record(BuildTestResult(name: groups[0]!, outcome: outcome))
            return true
        }
        if let groups = Self.panicPattern.match(line) {
            records.record(BuildTestResult(name: groups[0]!, path: groups[1], line: groups[2].flatMap { Int($0) }, column: groups[3].flatMap { Int($0) }, outcome: .failed))
            panickedTest = groups[0]!
            return true
        }
        if let groups = Self.oldPanicPattern.match(line) {
            records.record(BuildTestResult(name: groups[0]!, path: groups[2], line: groups[3].flatMap { Int($0) }, column: groups[4].flatMap { Int($0) }, outcome: .failed, message: groups[1]))
            return true
        }
        return false
    }

    private static let placePattern = LinePattern(#"^\s*--> (\S[^:]*):(\d+):(\d+)$"#)
    private static let summaryPattern = LinePattern(#"^(?:[\w.+-]+: )?(?:fatal error|error|warning)(?:\[\w+\])?: .*(?:could not compile|aborting due to)"#)
    private static let generatedWarnings = LinePattern(#"generated \d+ warnings?"#)
    private static let testPattern = LinePattern(#"^test (\S+) \.\.\. (ok|FAILED|ignored)"#)
    private static let panicPattern = LinePattern(#"^thread '([^']+)' panicked at (\S[^:]*):(\d+):(\d+):$"#)
    private static let oldPanicPattern = LinePattern(#"^thread '([^']+)' panicked at '(.*)', (\S[^:]*):(\d+):(\d+)$"#)
}
