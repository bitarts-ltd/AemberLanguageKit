/**
    @file BuildRecords.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief What a build or test run found: diagnostics and test results.
    @details
    Every parser (Aember's for compiler lines, a pack's
    BuildOutputParser for its tools' console output, a
    BuildReportReader for a report a command writes) turns what it
    reads into the same records: diagnostics (file, line, column,
    severity, message, notes) and test results (name, place, outcome,
    message, duration). BuildRecords collects them, dropping a
    diagnostic printed twice and merging what several lines say about
    one test.
*/

import Foundation

/// @brief How serious a diagnostic is
public enum BuildSeverity: String, Equatable, Sendable {
    case error
    case warning
    case note
}

/// @brief A note attached to a diagnostic, with its own place if any
public struct BuildNote: Equatable, Sendable {
    public var path: String?
    public var line: Int?
    public var column: Int?
    public var message: String

    /// @brief A note.
    /// @param path The file, if the note has a place
    /// @param line 1-based line
    /// @param column 1-based column
    /// @param message What it says
    /// @return The note
    public init(path: String? = nil, line: Int? = nil, column: Int? = nil, message: String) {
        self.path = path
        self.line = line
        self.column = column
        self.message = message
    }
}

/// @brief One error or warning from a build
public struct BuildDiagnostic: Equatable, Sendable {

    /// The file as printed, or as resolved against the project; nil
    /// for a diagnostic without a place, such as a linker error
    public var path: String?

    /// 1-based line
    public var line: Int?

    /// 1-based column
    public var column: Int?

    public var severity: BuildSeverity
    public var message: String
    public var notes: [BuildNote]

    /// @brief A diagnostic.
    /// @param path The file, if it has a place
    /// @param line 1-based line
    /// @param column 1-based column
    /// @param severity Error, warning or note
    /// @param message What it says
    /// @param notes Notes attached to it
    /// @return The diagnostic
    public init(path: String? = nil, line: Int? = nil, column: Int? = nil, severity: BuildSeverity, message: String, notes: [BuildNote] = []) {
        self.path = path
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
        self.notes = notes
    }
}

/// @brief How a test ended
public enum BuildTestOutcome: String, Equatable, Sendable {
    case passed
    case failed
    case skipped
}

/// @brief One test's result
public struct BuildTestResult: Equatable, Sendable {

    /// The name the test command's filter takes
    public var name: String

    /// A display name the test gave itself, when it differs
    public var displayName: String?

    /// Where it failed (or is declared), if known
    public var path: String?
    public var line: Int?
    public var column: Int?

    public var outcome: BuildTestOutcome

    /// Why it failed or was skipped
    public var message: String?

    /// Seconds it took
    public var duration: TimeInterval?

    /// @brief A test's result.
    /// @param name The name the test command's filter takes
    /// @param displayName A display name, when it differs
    /// @param path Where it failed or is declared
    /// @param line 1-based line
    /// @param column 1-based column
    /// @param outcome How it ended
    /// @param message Why it failed or was skipped
    /// @param duration Seconds it took
    /// @return The result
    public init(name: String, displayName: String? = nil, path: String? = nil, line: Int? = nil, column: Int? = nil, outcome: BuildTestOutcome, message: String? = nil, duration: TimeInterval? = nil) {
        self.name = name
        self.displayName = displayName
        self.path = path
        self.line = line
        self.column = column
        self.outcome = outcome
        self.message = message
        self.duration = duration
    }
}

/// @brief The diagnostics and test results a run found
public struct BuildRecords: Equatable, Sendable {

    public private(set) var diagnostics: [BuildDiagnostic] = []
    public private(set) var tests: [BuildTestResult] = []

    /// @brief The diagnostics already added, so a repeat is dropped
    private var diagnosticKeys = Set<String>()

    /// @brief Each test's index in tests, by name
    private var testIndex: [String: Int] = [:]

    /// @brief No records.
    /// @return The records
    public init() {
    }

    public var errorCount: Int {
        diagnostics.filter { $0.severity == .error }.count
    }

    public var warningCount: Int {
        diagnostics.filter { $0.severity == .warning }.count
    }

    public var passedCount: Int { tests.filter { $0.outcome == .passed }.count }
    public var failedCount: Int { tests.filter { $0.outcome == .failed }.count }
    public var skippedCount: Int { tests.filter { $0.outcome == .skipped }.count }

    /// @brief Adds a diagnostic unless the same one was added already.
    /// @detail
    /// xcodebuild and swift build can print a diagnostic more than once
    /// (per architecture, or again in a summary).
    /// @param diagnostic The diagnostic
    /// @return Whether it was added
    @discardableResult
    public mutating func add(_ diagnostic: BuildDiagnostic) -> Bool {
        let key = [
            diagnostic.path ?? "",
            diagnostic.line.map(String.init) ?? "",
            diagnostic.column.map(String.init) ?? "",
            diagnostic.severity.rawValue,
            diagnostic.message
        ].joined(separator: "\u{1}")
        guard diagnosticKeys.insert(key).inserted else { return false }
        diagnostics.append(diagnostic)
        return true
    }

    /// @brief Adds a note to the last diagnostic added.
    /// @param note The note
    /// @return Nothing
    public mutating func addNoteToLast(_ note: BuildNote) {
        guard !diagnostics.isEmpty else { return }
        diagnostics[diagnostics.count - 1].notes.append(note)
    }

    /// @brief Gives the last diagnostic a place, if it has none.
    /// @detail
    /// rustc prints the place on the line after the message.
    /// @param path The file
    /// @param line 1-based line
    /// @param column 1-based column
    /// @return Nothing
    public mutating func placeLast(path: String, line: Int, column: Int?) {
        guard let last = diagnostics.indices.last,
              diagnostics[last].path == nil
        else {
            return
        }
        diagnostics[last].path = path
        diagnostics[last].line = line
        diagnostics[last].column = column
    }

    /// @brief Records what a line says about a test.
    /// @detail
    /// Merged with what was recorded for the same name before: a later
    /// outcome and duration replace earlier ones (an issue marks the
    /// test failed until it reports how it ended), the first place is
    /// kept, and messages are joined.
    /// @param result What is known about the test
    /// @return Nothing
    public mutating func record(_ result: BuildTestResult) {
        guard let index = testIndex[result.name] else {
            testIndex[result.name] = tests.count
            tests.append(result)
            return
        }
        var merged = tests[index]
        // A failure stays a failure when a summary line follows
        if !(merged.outcome == .failed && result.outcome == .passed) {
            merged.outcome = result.outcome
        }
        merged.displayName = merged.displayName ?? result.displayName
        if merged.path == nil {
            merged.path = result.path
            merged.line = result.line
            merged.column = result.column
        }
        if let message = result.message, !message.isEmpty {
            merged.message = merged.message.map { $0 + "\n" + message }
                ?? message
        }
        merged.duration = result.duration ?? merged.duration
        tests[index] = merged
    }

    /// @brief Appends a line to a test's message.
    /// @param line The line
    /// @param name The test's name
    /// @return Nothing
    public mutating func appendToMessage(_ line: String, ofTest name: String) {
        guard let index = testIndex[name] else { return }
        tests[index].message = tests[index].message.map { $0 + "\n" + line }
            ?? line
    }

    /// @brief Replaces the tests with those a report gives.
    /// @detail
    /// A report (a result bundle, JUnit XML) knows more than the
    /// console; a place the console gave fills in one the report lacks.
    /// @param results The report's tests
    /// @return Nothing
    public mutating func replaceTests(with results: [BuildTestResult]) {
        let console = tests
        tests = []
        testIndex = [:]
        for var result in results {
            if result.path == nil,
               let match = console.first(where: {
                   Self.sameTest($0, result)
               }) {
                result.path = match.path
                result.line = match.line
                result.column = match.column
            }
            record(result)
        }
    }

    /// @brief Replaces the diagnostics with those a report gives.
    /// @param results The report's diagnostics
    /// @return Nothing
    public mutating func replaceDiagnostics(with results: [BuildDiagnostic]) {
        diagnostics = []
        diagnosticKeys = []
        for result in results {
            add(result)
        }
    }

    /// @brief Rewrites every path.
    /// @param transform Maps a path as printed to the path to keep
    /// @return Nothing
    public mutating func resolvePaths(_ transform: (String) -> String) {
        for index in diagnostics.indices {
            diagnostics[index].path = diagnostics[index].path.map(transform)
            for note in diagnostics[index].notes.indices {
                diagnostics[index].notes[note].path =
                    diagnostics[index].notes[note].path.map(transform)
            }
        }
        for index in tests.indices {
            tests[index].path = tests[index].path.map(transform)
        }
    }

    /// @brief Whether two records name the same test.
    /// @detail
    /// Names differ in form between the console and reports
    /// ("Module.Suite/test" against "Target/Suite/test()"), so the
    /// names' last components are compared, and display names.
    private static func sameTest(_ a: BuildTestResult, _ b: BuildTestResult) -> Bool {
        func last(_ name: String) -> String {
            let component = name.split(separator: "/").last.map(String.init) ?? name
            return component.hasSuffix("()")
                ? String(component.dropLast(2)) : component
        }
        let names = [a.name, a.displayName].compactMap { $0 }
        if names.contains(b.name)
            || b.displayName.map(names.contains) == true {
            return true
        }
        return last(a.name) == last(b.name)
    }
}

// MARK: - Reading output and reports

/// @brief Reads one tool's console output, a line at a time.
/// @details
/// Aember makes a fresh parser from each enabled pack's providers
/// for every run, and hands each line, with colours and carriage
/// returns removed, to the parsers in turn: first a parser in the
/// middle of a block (isReadingBlock), then every pack's parsers by
/// pack, and last Aember's own for compiler lines
/// (`path:line:column: error: message`), ld's undefined symbols and
/// lines without a place. The first that takes the line ends its
/// turn. So a parser takes only lines it is sure are its tool's.
public protocol BuildOutputParser: AnyObject {

    /// @brief Reads a line, if it is this parser's tool's.
    /// @param line The line, without escapes or its line break
    /// @param records What the run found so far
    /// @return True when the line was this parser's, and no other
    ///     parser should see it
    func consume(_ line: String, into records: inout BuildRecords) -> Bool

    /// @brief Ends the output: completes anything being read.
    /// @param records What the run found
    /// @return None
    func finish(into records: inout BuildRecords)

    /// Whether the parser is reading a block that the next lines
    /// continue (a test's failure details), so it sees them first
    var isReadingBlock: Bool { get }
}

extension BuildOutputParser {

    /// @brief Nothing to complete.
    /// @param records What the run found
    /// @return None
    public func finish(into records: inout BuildRecords) {
    }

    /// Not reading a block
    public var isReadingBlock: Bool { false }
}

/// @brief A regular expression matched against a whole line, for
/// output parsers.
public struct LinePattern: @unchecked Sendable {

    /// The expression
    public let expression: NSRegularExpression

    /// @brief A pattern.
    /// @details
    /// Patterns are constants, so one that doesn't compile is a
    /// programming error.
    /// @param pattern The regular expression
    /// @return The pattern
    public init(_ pattern: String) {
        // swiftlint:disable:next force_try
        expression = try! NSRegularExpression(pattern: pattern)
    }

    /// @brief Matches the pattern against a line.
    /// @param line The line
    /// @return Each capture group's text (nil for one that didn't take
    ///     part), or nil when the line doesn't match
    public func match(_ line: String) -> [String?]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let result = expression.firstMatch(in: line, range: range) else {
            return nil
        }
        return (1..<result.numberOfRanges).map { index -> String? in
            guard let found = Range<String.Index>(result.range(at: index), in: line) else {
                return nil
            }
            return String(line[found])
        }
    }
}

/// @brief Makes a pack's parser for one tool's output, once per run.
public struct BuildOutputParserProvider: Sendable {

    /// Stable across versions ("cargo", "swift-testing")
    public let identifier: String

    /// Makes a fresh parser
    public let make: @Sendable () -> any BuildOutputParser

    /// @brief A provider.
    /// @param identifier Its identifier
    /// @param make Makes a fresh parser
    /// @return The provider
    public init(identifier: String, make: @escaping @Sendable () -> any BuildOutputParser) {
        self.identifier = identifier
        self.make = make
    }
}

/// @brief What a report says, read after its run.
/// @details
/// Diagnostics from a report replace the console's only when the
/// console gave none; tests from a report replace the console's.
public struct BuildReport: Equatable, Sendable {

    /// Its diagnostics, nil when it has none to give
    public var diagnostics: [BuildDiagnostic]?

    /// Its tests, nil when it has none to give
    public var tests: [BuildTestResult]?

    /// @brief A report.
    /// @param diagnostics Its diagnostics
    /// @param tests Its tests
    /// @return The report
    public init(diagnostics: [BuildDiagnostic]? = nil, tests: [BuildTestResult]? = nil) {
        self.diagnostics = diagnostics
        self.tests = tests
    }
}

/// @brief Reads the reports of one format a command writes.
/// @details
/// A command names the report it writes and its format
/// (BuildCommand.report). Aember reads `junit` itself; any other
/// format is read by the reader with that identifier.
public struct BuildReportReader: Sendable {

    /// The format it reads ("xcresult"), as commands name it
    public let identifier: String

    /// Reads a report; nil when it can't be read
    public let read: @Sendable (URL) -> BuildReport?

    /// @brief A reader.
    /// @param identifier The format it reads
    /// @param read Reads a report
    /// @return The reader
    public init(identifier: String, read: @escaping @Sendable (URL) -> BuildReport?) {
        self.identifier = identifier
        self.read = read
    }
}
