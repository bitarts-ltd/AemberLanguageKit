/**
    @file TSCOutputParser.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Reads tsc's diagnostics: `path(line,column): error TS1234: message`.
*/

import Foundation
import AemberLanguageKit

// l10n-exempt-file: matches the English output of tsc

/// @brief Parses tsc's diagnostic lines
final class TSCOutputParser: BuildOutputParser {

    func consume(_ line: String, into records: inout BuildRecords) -> Bool {
        guard let groups = Self.pattern.match(line) else {
            return false
        }
        records.add(BuildDiagnostic(path: groups[0]!, line: Int(groups[1]!), column: Int(groups[2]!), severity: groups[3] == "warning" ? .warning : .error, message: groups[4]!))
        return true
    }

    private static let pattern = LinePattern(#"^(\S[^(]*)\((\d+),(\d+)\): (error|warning) (TS\d+: .*)$"#)
}
