/**
    @file MakeGenerator.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Generates compilation database using Make's database dump.
    @details
    Uses `make -p` to dump Make's internal rule database, then parses
    the structured output to extract variable definitions and compilation
    rules. Targets make listed without commands get them from the pattern
    rules in the database. More robust than parsing `make -n` output
    because it works even when source files don't exist. A recursive
    Makefile's sub-makes print databases of their own, and each one's
    commands are taken with the directory that make ran in.
*/

import Foundation
import AemberLanguageKit

/// @brief Generates compilation database using Make.
/// @detail
/// Its errors are CompilationDatabaseError's.
struct MakeGenerator {

    private let parser: MakeDatabaseParser
    private let filter = MakeCommandFilter()

    /// @brief Create a generator.
    /// @param executablePath Path to the make executable, or nil to
    /// locate it at run time
    /// @return Nothing
    init(executablePath: String? = nil) {
        parser = MakeDatabaseParser(executablePath: executablePath)
    }

    /// @brief Generate compilation database for a Make project.
    /// @details
    /// Runs make -p to dump the rule databases (one per make, for a
    /// recursive Makefile), parses them to extract variables and rules,
    /// expands variables in commands, filters for compilation commands,
    /// and generates compile_commands.json.
    /// @param projectURL The project root directory
    /// @param onOutput Optional callback for generator output lines
    /// @return URL of the generated compile_commands.json file
    func generate(
        projectURL: URL,
        onOutput: ((String) -> Void)? = nil
    ) async throws -> URL {
        onOutput?(
            PackStrings.text("Parsing Makefile database…").localized
        )

        // Parse make -p output
        let databases = try await parser.parse(projectURL: projectURL)

        var commands: [CompileCommand] = []
        for database in databases {
            commands += compileCommands(
                in: database,
                projectURL: projectURL,
                onOutput: onOutput
            )
        }

        guard !commands.isEmpty else {
            throw CompilationDatabaseError.noCompilationCommands
        }

        onOutput?(
            String(
                format: PackStrings.text("Extracted %d compilation commands").localized,
                commands.count
            )
        )

        let outputURL = try CompilationDatabaseFile.write(
            commands,
            projectURL: projectURL
        )
        onOutput?(
            PackStrings.text("Generated compilation database").localized
        )
        return outputURL
    }

    /// @brief The compile commands of one make's database.
    /// @detail
    /// Its rules, and those its pattern rules give targets listed
    /// without commands, have their variables expanded; the compile
    /// commands among them run in the directory that make ran in, or
    /// the project root when the database doesn't name one.
    /// @param database One make's database
    /// @param projectURL The project root, where the top-level make ran
    /// @param onOutput Optional callback for generator output lines
    /// @return The database's compile commands
    private func compileCommands(
        in database: MakeDatabase,
        projectURL: URL,
        onOutput: ((String) -> Void)?
    ) -> [CompileCommand] {
        let directory = database.directory
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? projectURL
        let variables = database.variables
        let rules = database.rules + resolveImplicitRules(
            database,
            directory: directory
        )

        onOutput?(
            String(
                format: PackStrings.text("Found %d variables and %d rules").localized,
                variables.count,
                rules.count
            )
        )

        let expander = MakeVariableExpander(variables: variables)
        var commands: [CompileCommand] = []

        for rule in rules {
            // Expand variables in each command
            for command in rule.commands {
                let expandedCommand = expander.expand(
                    command: command,
                    target: rule.target,
                    dependencies: rule.dependencies
                )

                // Keep compilation commands
                if filter.isCompilationCommand(expandedCommand),
                   let compileCmd = filter.extractCompileCommand(
                    from: expandedCommand,
                    workingDirectory: directory.path
                   ) {
                    commands.append(compileCmd)
                }
            }
        }
        return commands
    }

    /// @brief Build rules for targets make listed without commands.
    /// @detail
    /// Applies the database's pattern rules to its command-less file
    /// entries. A prerequisite qualifies if it exists in the directory
    /// make ran in or make knows it as a file, which is make's "exists
    /// or ought to exist" test.
    /// @param database One make's database
    /// @param directory The directory that make ran in
    /// @return Rules for the targets a pattern rule applies to
    private func resolveImplicitRules(
        _ database: MakeDatabase,
        directory: URL
    ) -> [MakeRule] {
        let resolver = MakeImplicitRuleResolver(
            patternRules: database.patternRules
        )
        let knownFiles = Set(
            (database.rules + database.targetsWithoutCommands).map(\.target)
        )
        let fileExists = { (path: String) -> Bool in
            knownFiles.contains(path) || FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: path, relativeTo: directory).path
            )
        }
        return database.targetsWithoutCommands.compactMap {
            resolver.resolve($0, fileExists: fileExists)
        }
    }
}
