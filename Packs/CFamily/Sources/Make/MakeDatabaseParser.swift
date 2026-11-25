/**
    @file MakeDatabaseParser.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Parses Make's internal database dump from `make -p`.
    @details
    Executes `make -p -n` to get Make's internal rule database, then parses
    the structured output to extract variable definitions, file rules, and
    the pattern rules from the implicit rules section, which
    MakeImplicitRuleResolver applies to file entries make printed without
    commands. This is more robust than parsing `make -n` output because it
    provides structured data even when source files don't exist.

    Even with -n, make runs the commands that invoke $(MAKE), so a
    recursive Makefile prints one database per sub-make, each when that
    make finishes, ending with the top-level one. Each is parsed on its
    own, with the directory its make ran in (its CURDIR).
*/

import Foundation
import AemberLanguageKit

// l10n-exempt-file: matches make's English database dump

/// @brief A Make rule extracted from the database.
struct MakeRule {
    /// The target name (e.g., "main.o")
    let target: String

    /// Dependencies (e.g., ["main.c", "utils.h"])
    let dependencies: [String]

    /// Commands to execute (tab-indented lines)
    let commands: [String]
}

/// @brief The parts of Make's database used to find compile commands.
struct MakeDatabase {
    /// Variable definitions (name → unexpanded value)
    let variables: [String: String]

    /// File entries with commands
    let rules: [MakeRule]

    /// Pattern rules with commands from the implicit rules section, in
    /// the order make tries them
    let patternRules: [MakeRule]

    /// File entries without commands, such as targets make never
    /// searched implicit rules for because they are not needed by the
    /// default goal
    let targetsWithoutCommands: [MakeRule]

    /// The directory make ran in (its CURDIR), where the rules'
    /// commands run, or nil if the database doesn't say
    var directory: String? {
        variables["CURDIR"]
    }

    /// A database with nothing in it
    static let empty = MakeDatabase(
        variables: [:],
        rules: [],
        patternRules: [],
        targetsWithoutCommands: []
    )
}

/// @brief Parses Make's internal database output.
class MakeDatabaseParser {

    /// Sections of make -p output the parser reads
    private enum Section {
        case variables
        case implicitRules
        case files
        case other
    }

    /// Start of the line that ends the database dump
    private static let endMarker = "# Finished Make data base"

    /// A variable assignment: VAR = value, VAR := value or VAR ?= value.
    /// Names may contain "." and "-", as in the built-in COMPILE.c and
    /// LINK.o. Compiled once: a dump has thousands of variables.
    // swiftlint:disable:next force_try
    private static let assignmentPattern = try! NSRegularExpression(
        pattern: "^([A-Za-z_][A-Za-z0-9_.-]*)\\s*[:?]?=\\s*(.*)$"
    )

    /// Path to the make executable, or nil to search for it
    private let executablePath: String?

    /// @brief Create a parser.
    /// @param executablePath Path to the make executable, or nil to
    /// locate it at run time
    /// @return Nothing
    init(executablePath: String? = nil) {
        self.executablePath = executablePath
    }

    /// @brief Execute make -p and parse its databases.
    /// @param projectURL The project directory containing the Makefile
    /// @return The parsed databases, the sub-makes' first and the
    /// top-level make's last
    func parse(projectURL: URL) async throws -> [MakeDatabase] {
        // Execute make -p -n
        let output = try await executeMakeDatabaseDump(projectURL: projectURL)

        // Parse the output
        return parseDatabases(output)
    }

    // MARK: - Private Methods

    /// @brief Execute make -p -n to dump database.
    /// @param projectURL The project directory
    /// @return The stdout output from make
    private func executeMakeDatabaseDump(projectURL: URL) async throws -> String {
        // Find make executable
        guard let makePath = executablePath
            ?? ExecutableFinder.findExecutable(named: "make") else {
            throw CompilationDatabaseError.toolNotFound("make")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: makePath)
        // -e: Environment variables override Makefile assignments
        // -p: Print database
        // -n: Don't run commands
        process.arguments = ["-e", "-p", "-n"]
        process.currentDirectoryURL = projectURL

        // Load environment from .aember/make-env if it exists
        var environment = BuildEnvironmentLoader.loadEnvironment(
            projectURL: projectURL,
            identifier: "make"
        )
        // Ensure consistent output format
        environment["LC_ALL"] = "C"
        process.environment = environment

        // Capture output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Run process
        try process.run()

        // Drain stdout and stderr, then wait for make to exit
        let (outputData, _) = await process.readToEnd(
            output: outputPipe,
            error: errorPipe
        )

        guard let output = String(data: outputData, encoding: .utf8) else {
            throw CompilationDatabaseError.invalidOutput
        }

        // Check exit status (make -p -n can succeed even if build would fail)
        if process.terminationStatus != 0 && process.terminationStatus != 2 {
            // Status 2 is common when Makefile has issues but database still dumps
            // Only fail if we got no output
            if output.isEmpty {
                throw CompilationDatabaseError.makeExecutionFailed(
                    status: process.terminationStatus
                )
            }
        }

        return output
    }

    /// @brief Parse the first database in make -p output (for tests).
    /// @param output The raw make -p output
    /// @return The first database, or an empty one if there is none
    func parseOutput(_ output: String) -> MakeDatabase {
        return parseDatabases(output).first ?? .empty
    }

    /// @brief Parse make -p output into its databases.
    /// @detail
    /// A database starts at its first section header and ends at the
    /// end marker (or the end of the output). In each, reads variable
    /// assignments from the variables section, pattern rules with
    /// commands from the implicit rules section, and file entries from
    /// the files section. Everything else, such as the commands a
    /// recursive make prints between databases, is ignored.
    /// @param output The raw make -p output
    /// @return The databases, in the order make printed them
    func parseDatabases(_ output: String) -> [MakeDatabase] {
        var databases: [MakeDatabase] = []
        var variables: [String: String] = [:]
        var rules: [MakeRule] = []
        var patternRules: [MakeRule] = []
        var targetsWithoutCommands: [MakeRule] = []
        var inDatabase = false

        func finishDatabase() {
            guard inDatabase else { return }
            databases.append(MakeDatabase(
                variables: variables,
                rules: rules,
                patternRules: patternRules,
                targetsWithoutCommands: targetsWithoutCommands
            ))
            variables = [:]
            rules = []
            patternRules = []
            targetsWithoutCommands = []
            inDatabase = false
        }

        let lines = output.components(separatedBy: .newlines)
        var section = Section.other
        var i = 0

        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix(Self.endMarker) {
                finishDatabase()
                section = .other
                i += 1
                continue
            }

            if let header = Self.section(forHeader: line) {
                inDatabase = true
                section = header
                i += 1
                continue
            }

            // Skip comments and empty lines
            if line.hasPrefix("#")
                || line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            switch section {
            case .variables:
                // Parse variable assignment: VAR = value or VAR := value
                if let (name, value) = parseVariableAssignment(line) {
                    variables[name] = value
                }
                i += 1

            case .implicitRules, .files:
                // Parse rule: target: dependencies
                let originalIndex = i
                if let rule = parseRule(lines: lines, startIndex: &i) {
                    if section == .implicitRules {
                        // Pattern rules without commands only cancel
                        // built-in rules, so they build nothing
                        if rule.target.contains("%"),
                           !rule.commands.isEmpty {
                            patternRules.append(rule)
                        }
                    } else if rule.commands.isEmpty {
                        targetsWithoutCommands.append(rule)
                    } else {
                        rules.append(rule)
                    }
                }
                // parseRule advances past the rule and its commands;
                // when it rejects the line without advancing, step over
                // it here
                if i == originalIndex {
                    i += 1
                }

            case .other:
                i += 1
            }
        }

        finishDatabase()
        return databases
    }

    /// @brief Identify a section header line.
    /// @param line A line of make -p output
    /// @return The section the header starts, or nil if the line is not
    /// a section header
    private static func section(forHeader line: String) -> Section? {
        switch line.trimmingCharacters(in: .whitespaces) {
        case "# Variables":
            return .variables
        case "# Implicit Rules":
            return .implicitRules
        case "# Files":
            return .files
        case "# Pattern-specific Variable Values",
             "# Directories",
             "# VPATH Search Paths":
            return .other
        default:
            return nil
        }
    }

    /// @brief Parse a variable assignment line.
    /// @param line The line to parse
    /// @return Tuple of (variable name, value) or nil
    private func parseVariableAssignment(_ line: String) -> (String, String)? {
        guard let match = Self.assignmentPattern.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ) else {
            return nil
        }

        let nsString = line as NSString
        let name = nsString.substring(with: match.range(at: 1))
        let value = nsString.substring(with: match.range(at: 2))

        return (name, value)
    }

    /// @brief Parse a rule starting at the given index.
    /// @detail
    /// Reads the rule line and the comments and commands that follow,
    /// stopping before the next rule, section header, or end marker.
    /// @param lines All lines from make -p output
    /// @param startIndex Index to start parsing (will be updated)
    /// @return Parsed MakeRule, possibly without commands, or nil if the
    /// line is not a rule
    private func parseRule(lines: [String], startIndex: inout Int) -> MakeRule? {
        let line = lines[startIndex]

        // Rules must contain ':'
        guard line.contains(":") else {
            return nil
        }

        // Skip old-style suffix rules (like .c.o:) but NOT pattern rules (%.o: %.c)
        if line.hasPrefix(".") && !line.hasPrefix("..") {
            return nil
        }

        // Parse: target: dependencies or target:: dependencies
        guard let colon = line.firstIndex(of: ":") else {
            return nil
        }
        let target = line[..<colon].trimmingCharacters(in: .whitespaces)
        var rest = line[line.index(after: colon)...]
        if rest.hasPrefix(":") {
            rest = rest.dropFirst()
        }
        let dependencies = rest
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        startIndex += 1

        var commands: [String] = []

        while startIndex < lines.count {
            let commandLine = lines[startIndex]

            // Leave section headers and the end marker to the caller
            if commandLine.hasPrefix(Self.endMarker)
                || Self.section(forHeader: commandLine) != nil {
                break
            }

            // Skip comment lines ("#  commands to execute (from
            // `Makefile', line 42):" among them) while looking for
            // commands
            if commandLine.hasPrefix("#") {
                startIndex += 1
                continue
            }

            // Skip blank lines
            if commandLine.trimmingCharacters(in: .whitespaces).isEmpty {
                startIndex += 1
                continue
            }

            // Commands start with tab
            if commandLine.hasPrefix("\t") {
                let command = String(commandLine.dropFirst())
                commands.append(command)
                startIndex += 1
                continue
            }

            // End of this rule (non-comment, non-blank, non-command line)
            break
        }

        return MakeRule(
            target: target,
            dependencies: dependencies,
            commands: commands
        )
    }
}
