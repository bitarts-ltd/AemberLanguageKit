/**
    @file MakeImplicitRuleResolverTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for MakeImplicitRuleResolver.
    @details
    Covers GNU make's pattern matching (file-name-only matching for
    patterns without a slash, non-empty stems), prerequisite
    instantiation, rule order, and the prerequisite existence test.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import CFamilyPack

@Suite("MakeImplicitRuleResolver")
struct MakeImplicitRuleResolverTests {

    /// @brief Create a pattern rule.
    /// @param target Target pattern
    /// @param dependencies Prerequisite patterns
    /// @param command The single command
    /// @return The rule
    private func pattern(
        _ target: String,
        _ dependencies: [String],
        _ command: String
    ) -> MakeRule {
        return MakeRule(
            target: target,
            dependencies: dependencies,
            commands: [command]
        )
    }

    /// @brief Create a file entry without commands.
    /// @param target Target name
    /// @param dependencies Its own prerequisites
    /// @return The rule
    private func entry(
        _ target: String,
        _ dependencies: [String] = []
    ) -> MakeRule {
        return MakeRule(
            target: target,
            dependencies: dependencies,
            commands: []
        )
    }

    /// @brief Matching splits off the directory only for patterns
    /// without a slash.
    @Test(arguments: [
        ("a.o", "%.o", "", "a"),
        ("src/a.o", "%.o", "src/", "a"),
        ("src/sub/liba.o", "lib%.o", "src/sub/", "a"),
        ("obj/x/a.o", "obj/%.o", "", "x/a"),
    ])
    func matches(
        fileName: String,
        pattern: String,
        directory: String,
        stem: String
    ) throws {
        let match = try #require(
            MakeImplicitRuleResolver.match(fileName, pattern: pattern)
        )
        #expect(match.directory == directory)
        #expect(match.stem == stem)
    }

    /// @brief Names that differ in prefix or suffix, would leave an
    /// empty stem, or patterns without `%` do not match.
    @Test(arguments: [
        ("a.c", "%.o"),
        ("src/a.o", "obj/%.o"),
        ("a.o", "lib%.o"),
        (".o", "%.o"),
        ("lib.o", "lib%.o"),
        ("a.o", "a.o"),
    ])
    func doesNotMatch(fileName: String, pattern: String) {
        #expect(
            MakeImplicitRuleResolver.match(fileName, pattern: pattern)
                == nil
        )
    }

    /// @brief The directory goes in front of instantiated prerequisites;
    /// literal prerequisites are unchanged.
    @Test func instantiatesPrerequisites() {
        let match = (directory: "src/", stem: "a")
        #expect(MakeImplicitRuleResolver.instantiate("lib%.c", with: match)
            == "src/liba.c")
        #expect(MakeImplicitRuleResolver.instantiate("config.h", with: match)
            == "config.h")
    }

    /// @brief The first matching rule with existing prerequisites wins,
    /// and the target's own prerequisites follow the implicit ones.
    @Test func resolvesFirstApplicableRule() throws {
        let resolver = MakeImplicitRuleResolver(patternRules: [
            pattern("obj/%.o", ["src/%.c"], "obj"),
            pattern("%.o", ["%.cpp"], "cpp"),
            pattern("%.o", ["%.c"], "c"),
            pattern("%.o", ["%.m"], "m"),
        ])
        let rule = try #require(resolver.resolve(
            entry("src/t.o", ["t.h", "src/t.c"]),
            fileExists: { ["src/t.c", "src/t.m"].contains($0) }
        ))
        #expect(rule.target == "src/t.o")
        #expect(rule.commands == ["c"])
        #expect(rule.dependencies == ["src/t.c", "t.h"])
    }

    /// @brief Without existing prerequisites no rule applies.
    @Test func missingPrerequisitesResolveNothing() {
        let resolver = MakeImplicitRuleResolver(patternRules: [
            pattern("%.o", ["%.c", "config.h"], "c"),
        ])
        #expect(resolver.resolve(
            entry("a.o"),
            fileExists: { $0 == "a.c" }
        ) == nil)
    }
}
