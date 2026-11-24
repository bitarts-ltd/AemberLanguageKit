/**
    @file LockfileText.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Reading pnpm's and Yarn's lockfiles
    @details
    pnpm-lock.yaml and Yarn 2+'s yarn.lock are YAML, and Yarn 1's
    yarn.lock is a format of its own with the same shape: keys nested
    by indentation. LockfileText reads both into dictionaries of
    strings, as JSONSerialization would, without a YAML library. It
    reads what the tools write: block mappings and "- " sequences by
    indentation, plain, single and double quoted scalars, and flow
    mappings and sequences ({integrity: ...}, [x64]); in Yarn 1's style
    a key and its value are separated by a space (version "1.2.3")
    rather than ": ". Every scalar stays a string ("true", "8"); a key
    with nothing under it is an empty string. Anchors, tags, multi-line
    scalars and documents aren't read, as lockfiles don't use them.

    A lockfile key can list several descriptors ("a@^1, a@^2" in
    Yarn 2+, `"a@^1", a@^2` in Yarn 1); descriptors(ofKey:) splits them.
*/

import Foundation
import AemberLanguageKit

/// @brief Reads the YAML lockfiles write, and Yarn 1's lockfile
enum LockfileText {

    /// How a file separates keys from values
    enum Style {

        /// YAML: "key: value" (pnpm-lock.yaml, Yarn 2+'s yarn.lock)
        case yaml

        /// Yarn 1's yarn.lock: "key value", and "key:" before a block
        case yarnClassic
    }

    /// @brief Reads a lockfile.
    /// @param text The file's text
    /// @param style How it separates keys from values
    /// @return The top-level mapping; empty when there is none
    static func parse(_ text: String, style: Style = .yaml) -> [String: Any] {
        var lines: [Line] = []
        for raw in text.components(separatedBy: .newlines) {
            let content = raw.drop { $0 == " " }
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), trimmed != "---" else { continue }
            lines.append(Line(indent: raw.count - content.count, text: trimmed))
        }
        var parser = Parser(lines: lines, style: style)
        guard let first = lines.first else { return [:] }
        return parser.mapping(indent: first.indent)
    }

    /// @brief The descriptors a lockfile key lists, unquoted.
    /// @param key "a@^1, a@^2" or `"a@^1", a@^2`
    /// @return ["a@^1", "a@^2"]
    static func descriptors(ofKey key: String) -> [String] {
        splitTopLevel(key, separator: ",").map { unquoted($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    // MARK: - Lines

    /// One line that isn't blank or a comment
    private struct Line {

        /// Its leading spaces
        var indent: Int

        /// The rest, trimmed
        var text: String
    }

    /// Reads the lines from the top, one block at a time
    private struct Parser {

        let lines: [Line]
        let style: Style
        var index = 0

        init(lines: [Line], style: Style) {
            self.lines = lines
            self.style = style
        }

        /// @brief Reads the mapping whose keys are at an indentation.
        /// @param indent The keys' indentation
        /// @return The mapping
        mutating func mapping(indent: Int) -> [String: Any] {
            var result: [String: Any] = [:]
            while index < lines.count {
                let line = lines[index]
                if line.indent < indent {
                    break
                }
                index += 1
                // A line deeper than the block is under no key: skip it
                guard line.indent == indent, let (key, value) = split(line.text) else { continue }
                if value.isEmpty {
                    result[key] = nested(under: indent)
                } else {
                    result[key] = style == .yaml ? LockfileText.scalar(value) : LockfileText.unquoted(value)
                }
            }
            return result
        }

        /// @brief Reads what is under a key with no value on its line: a
        /// deeper mapping or sequence, else an empty string.
        /// @param indent The key's indentation
        /// @return The value
        mutating func nested(under indent: Int) -> Any {
            guard index < lines.count else { return "" }
            let next = lines[index]
            if next.indent > indent {
                return isItem(next.text) ? sequence(indent: next.indent) : mapping(indent: next.indent)
            }
            // YAML lets a sequence sit at its key's indentation
            if style == .yaml, next.indent == indent, isItem(next.text) {
                return sequence(indent: indent)
            }
            return ""
        }

        /// @brief Reads the "- " items at an indentation.
        /// @param indent The items' indentation
        /// @return The items, as scalars
        mutating func sequence(indent: Int) -> [Any] {
            var result: [Any] = []
            while index < lines.count, lines[index].indent == indent, isItem(lines[index].text) {
                let text = lines[index].text.dropFirst().trimmingCharacters(in: .whitespaces)
                index += 1
                result.append(LockfileText.scalar(text))
            }
            return result
        }

        /// @brief Whether a line is a sequence item.
        func isItem(_ text: String) -> Bool {
            text == "-" || text.hasPrefix("- ")
        }

        /// @brief A line's key and the value on its line.
        /// @param text The line, trimmed
        /// @return The key, unquoted when it is one quoted string, and the
        /// value ("" when the line ends the key with ":"), or nil
        func split(_ text: String) -> (String, String)? {
            switch style {
            case .yaml:
                if let quote = text.first, quote == "'" || quote == "\"",
                   let end = LockfileText.closingQuote(in: text) {
                    let rest = text[text.index(after: end)...].trimmingCharacters(in: .whitespaces)
                    guard rest.hasPrefix(":") else { return nil }
                    return (LockfileText.unquoted(String(text[...end])), rest.dropFirst().trimmingCharacters(in: .whitespaces))
                }
                if let range = text.range(of: ": ") {
                    return (String(text[..<range.lowerBound]), text[range.upperBound...].trimmingCharacters(in: .whitespaces))
                }
                return text.hasSuffix(":") ? (String(text.dropLast()), "") : nil
            case .yarnClassic:
                if text.hasSuffix(":") {
                    let key = String(text.dropLast())
                    let parts = LockfileText.descriptors(ofKey: key)
                    // One quoted key reads unquoted; a list stays as written
                    return (parts.count == 1 ? parts[0] : key, "")
                }
                guard let space = LockfileText.firstUnquotedSpace(in: text) else { return nil }
                return (LockfileText.unquoted(String(text[..<space])), text[text.index(after: space)...].trimmingCharacters(in: .whitespaces))
            }
        }
    }

    // MARK: - Scalars

    /// @brief A YAML value on one line: a quoted or plain scalar, or a
    /// flow mapping or sequence.
    /// @param text The value, trimmed
    /// @return A string, [String: Any] or [Any]
    static func scalar(_ text: String) -> Any {
        if text.hasPrefix("{"), text.hasSuffix("}") {
            var result: [String: Any] = [:]
            for item in splitTopLevel(String(text.dropFirst().dropLast()), separator: ",") {
                let entry = item.trimmingCharacters(in: .whitespaces)
                guard !entry.isEmpty else { continue }
                let range = entry.range(of: ": ") ?? entry.range(of: ":")
                guard let range else {
                    result[unquoted(entry)] = ""
                    continue
                }
                let key = entry[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                result[unquoted(key)] = scalar(entry[range.upperBound...].trimmingCharacters(in: .whitespaces))
            }
            return result
        }
        if text.hasPrefix("["), text.hasSuffix("]") {
            return splitTopLevel(String(text.dropFirst().dropLast()), separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { scalar($0) }
        }
        return unquoted(text)
    }

    /// @brief A scalar without its quotes: '' in single quotes is one ',
    /// and \" and \\ in double quotes are " and \.
    /// @param text The scalar
    /// @return The text, as is when not quoted
    static func unquoted(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == text.last, first == "'" || first == "\"" else {
            return text
        }
        let inner = String(text.dropFirst().dropLast())
        if first == "'" {
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        var result = ""
        var escaped = false
        for character in inner {
            if escaped {
                result.append(character == "n" ? "\n" : character == "t" ? "\t" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// @brief Where the quote opening a text closes.
    /// @param text Text starting with ' or "
    /// @return The closing quote's index, or nil
    static func closingQuote(in text: String) -> String.Index? {
        guard let quote = text.first else { return nil }
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if quote == "\"", character == "\\" {
                index = text.index(after: index)
                if index < text.endIndex {
                    index = text.index(after: index)
                }
                continue
            }
            if character == quote {
                let next = text.index(after: index)
                // '' inside single quotes is a quote, not the end
                if quote == "'", next < text.endIndex, text[next] == "'" {
                    index = text.index(after: next)
                    continue
                }
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// @brief The first space outside double quotes.
    /// @param text The line
    /// @return Its index, or nil
    static func firstUnquotedSpace(in text: String) -> String.Index? {
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                quoted.toggle()
            } else if character == " ", !quoted {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// @brief Splits text at a separator outside quotes, braces and
    /// brackets.
    /// @param text The text
    /// @param separator The separator
    /// @return The parts, untrimmed
    static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open {
                    quote = nil
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "{" || character == "[" {
                depth += 1
            } else if character == "}" || character == "]" {
                depth -= 1
            } else if character == separator, depth == 0 {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        parts.append(current)
        return parts
    }
}
