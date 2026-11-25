/**
    @file BuildOutputSupport.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Feeds console output to a pack's BuildOutputParser, as Aember
    does, for the packs' tests.
*/

import Foundation
import AemberLanguageKit

/// @brief What a parser made of some output
public struct ParsedOutput {

    /// What it recorded
    public var records: BuildRecords

    /// The lines it left for other parsers, in order
    public var unread: [String]
}

/// @brief Feeds text to a parser a line at a time, then finishes it.
/// @param text The output
/// @param parser The parser
/// @return What it recorded, and the lines it didn't take
public func parseOutput(_ text: String, with parser: any BuildOutputParser) -> ParsedOutput {
    var records = BuildRecords()
    var unread: [String] = []
    for line in text.components(separatedBy: "\n") where !parser.consume(line, into: &records) {
        unread.append(line)
    }
    parser.finish(into: &records)
    return ParsedOutput(records: records, unread: unread)
}
