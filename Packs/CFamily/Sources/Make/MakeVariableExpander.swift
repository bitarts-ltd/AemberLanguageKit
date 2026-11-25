/**
    @file MakeVariableExpander.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Expands Make variable references in commands.
    @details
    Expands $(VAR) and ${VAR} references using a variable dictionary,
    a pass at a time until nothing changes (at most 100 passes, which
    ends a variable that refers to itself); undefined variables expand
    to the empty string. Functions such as $(patsubst ...) are not
    expanded. Then handles automatic variables like $@, $<, $^, $? in
    the context of a specific rule (target and dependencies).
*/

import Foundation
import AemberLanguageKit

/// @brief Expands Make variable references.
class MakeVariableExpander {

    private let variables: [String: String]

    /// $(VAR) and ${VAR}; names may contain "." and "-", as in the
    /// built-in COMPILE.c. Compiled once, not per pass of each command.
    private static let referencePatterns = [
        "\\$\\(([A-Za-z_][A-Za-z0-9_.-]*)\\)",
        "\\$\\{([A-Za-z_][A-Za-z0-9_.-]*)\\}"
    ].map {
        // The patterns are constants, so a bad one is a programming error
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: $0)
    }

    /// @brief Initialize with a variable dictionary.
    /// @param variables Dictionary of variable name → value
    init(variables: [String: String]) {
        self.variables = variables
    }

    /// @brief Expand all variables in a command string.
    /// @param command The command with $(VAR) references
    /// @param target The rule target (for automatic variables like $@)
    /// @param dependencies The rule dependencies (for automatic variables like $<)
    /// @return Fully expanded command string
    func expand(
        command: String,
        target: String,
        dependencies: [String]
    ) -> String {
        var result = command

        // Expand user-defined variables first, so automatic variables in
        // their values (OUTPUT_OPTION = -o $@) are expanded below
        result = expandUserVariables(result)

        // Expand automatic variables
        result = expandAutomaticVariables(
            result,
            target: target,
            dependencies: dependencies
        )

        return result
    }

    // MARK: - Private Methods

    /// @brief Expand automatic variables ($@, $<, $^, etc.).
    /// @param text The text to expand
    /// @param target The rule target
    /// @param dependencies The rule dependencies
    /// @return Text with automatic variables expanded
    private func expandAutomaticVariables(
        _ text: String,
        target: String,
        dependencies: [String]
    ) -> String {
        var result = text

        // $@ - The target filename
        result = result.replacingOccurrences(of: "$@", with: target)

        // $< - The first dependency
        if let firstDep = dependencies.first {
            result = result.replacingOccurrences(of: "$<", with: firstDep)
        }

        // $^ - All dependencies (space-separated)
        let allDeps = dependencies.joined(separator: " ")
        result = result.replacingOccurrences(of: "$^", with: allDeps)

        // $? - Dependencies newer than target (we'll use all for now)
        result = result.replacingOccurrences(of: "$?", with: allDeps)

        // $* - The stem (for pattern rules - simplified)
        // For now, just remove the extension from target
        let stem = (target as NSString).deletingPathExtension
        result = result.replacingOccurrences(of: "$*", with: stem)

        return result
    }

    /// @brief Expand user-defined variables $(VAR) and ${VAR}.
    /// @param text The text to expand
    /// @return Text with variables expanded
    private func expandUserVariables(_ text: String) -> String {
        var result = text

        // Keep expanding until no more variables found; the limit ends
        // a variable that refers to itself
        var previousResult = ""
        var iterations = 0
        let maxIterations = 100

        while result != previousResult && iterations < maxIterations {
            previousResult = result
            result = expandSinglePass(result)
            iterations += 1
        }

        return result
    }

    /// @brief Perform one pass of variable expansion.
    /// @detail
    /// Replaces every $(VAR) and ${VAR} reference with its value, or
    /// with the empty string when VAR is undefined, as make does.
    /// @param text The text to expand
    /// @return Text with one level of variables expanded
    private func expandSinglePass(_ text: String) -> String {
        let result = NSMutableString(string: text)

        for regex in Self.referencePatterns {
            // Replace from the end, so earlier ranges stay valid
            let matches = regex.matches(
                in: result as String,
                range: NSRange(location: 0, length: result.length)
            ).reversed()

            for match in matches {
                let varName = result.substring(with: match.range(at: 1))
                // Like make, an undefined variable expands to the empty
                // string
                let value = variables[varName] ?? ""
                result.replaceCharacters(in: match.range, with: value)
            }
        }

        return result as String
    }
}
