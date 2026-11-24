/**
    @file MakeImplicitRuleResolver.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Applies Make pattern rules to targets listed without commands.
    @details
    `make -p -n` only searches implicit rules for targets the default goal
    needs, so objects built for other goals appear in the files section
    without commands. This applies the pattern rules from the implicit
    rules section to such targets the way make would: the first pattern
    rule whose target pattern matches and whose prerequisites exist (or
    are known to make) supplies the commands.
*/

import Foundation
import AemberLanguageKit

/// @brief Finds the pattern rule make would use for a target.
struct MakeImplicitRuleResolver {

    /// Pattern rules in the order make tries them
    let patternRules: [MakeRule]

    /// @brief Build a rule for a target from the first pattern rule that
    /// applies.
    /// @detail
    /// The resulting rule's prerequisites are the pattern rule's,
    /// instantiated with the stem, followed by the target's own
    /// prerequisites, so `$<` names the implicit source as it does in
    /// make.
    /// @param target A file entry without commands
    /// @param fileExists Whether a prerequisite exists or ought to
    /// exist; paths are as make prints them
    /// @return The instantiated rule, or nil if no pattern rule applies
    func resolve(
        _ target: MakeRule,
        fileExists: (String) -> Bool
    ) -> MakeRule? {
        for patternRule in patternRules {
            guard let match = Self.match(
                target.target,
                pattern: patternRule.target
            ) else {
                continue
            }

            let prerequisites = patternRule.dependencies.map {
                Self.instantiate($0, with: match)
            }
            guard prerequisites.allSatisfy(fileExists) else {
                continue
            }

            let ownPrerequisites = target.dependencies.filter {
                !prerequisites.contains($0)
            }
            return MakeRule(
                target: target.target,
                dependencies: prerequisites + ownPrerequisites,
                commands: patternRule.commands
            )
        }
        return nil
    }

    /// @brief Match a file name against a target pattern.
    /// @detail
    /// A pattern without a slash is matched against the file name alone,
    /// as make does; the file's directory is then put back on the
    /// prerequisites. The stem must not be empty.
    /// @param fileName The target file name
    /// @param pattern A target pattern containing `%`
    /// @return The directory to prefix prerequisites with and the stem,
    /// or nil if the name does not match
    static func match(
        _ fileName: String,
        pattern: String
    ) -> (directory: String, stem: String)? {
        guard let percent = pattern.firstIndex(of: "%") else {
            return nil
        }
        let prefix = pattern[..<percent]
        let suffix = pattern[pattern.index(after: percent)...]

        var directory = ""
        var name = Substring(fileName)
        if !pattern.contains("/"),
           let slash = fileName.lastIndex(of: "/") {
            directory = String(fileName[...slash])
            name = fileName[fileName.index(after: slash)...]
        }

        guard name.count > prefix.count + suffix.count,
              name.hasPrefix(prefix),
              name.hasSuffix(suffix) else {
            return nil
        }
        let stem = name.dropFirst(prefix.count).dropLast(suffix.count)
        return (directory, String(stem))
    }

    /// @brief Substitute a match into a prerequisite pattern.
    /// @param prerequisite A prerequisite, with or without `%`
    /// @param match The directory and stem from match(_:pattern:)
    /// @return The prerequisite file name; one without `%` is unchanged
    static func instantiate(
        _ prerequisite: String,
        with match: (directory: String, stem: String)
    ) -> String {
        guard let percent = prerequisite.range(of: "%") else {
            return prerequisite
        }
        return match.directory
            + prerequisite.replacingCharacters(in: percent, with: match.stem)
    }
}
