/**
    @file MakeVariableExpanderTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for MakeVariableExpander.
    @details
    Covers automatic variables ($@, $<, $^, $?, $*), $(VAR) and ${VAR}
    references, nested and dotted names, undefined variables, and
    termination on circular definitions.
*/

import Testing
import AemberLanguageKit
import PackTestSupport
@testable import CFamilyPack

@Suite("MakeVariableExpander")
struct MakeVariableExpanderTests {

    /// @brief Expand a command for target out.o built from a.c and a.h.
    /// @param command The recipe line
    /// @param variables Variable definitions
    /// @return The expanded command
    private func expand(
        _ command: String,
        _ variables: [String: String] = [:]
    ) -> String {
        return MakeVariableExpander(variables: variables).expand(
            command: command,
            target: "dir/out.o",
            dependencies: ["a.c", "a.h"]
        )
    }

    /// @brief Automatic variables expand from the target and deps.
    @Test(arguments: [
        ("$@", "dir/out.o"),
        ("$<", "a.c"),
        ("$^", "a.c a.h"),
        ("$?", "a.c a.h"),
        ("$*", "dir/out"),
        ("cc -c $< -o $@", "cc -c a.c -o dir/out.o"),
    ])
    func automaticVariables(command: String, expected: String) {
        #expect(expand(command) == expected)
    }

    /// @brief $< is left alone when there are no dependencies, and $^
    /// becomes empty.
    @Test func automaticVariablesWithoutDependencies() {
        let expander = MakeVariableExpander(variables: [:])
        let result = expander.expand(
            command: "x $< y $^ z",
            target: "t",
            dependencies: []
        )
        #expect(result == "x $< y  z")
    }

    /// @brief Both reference syntaxes expand, including nested values
    /// and names containing dots.
    @Test func userVariables() {
        let variables = [
            "CC": "clang",
            "CFLAGS": "-O2 $(WARN)",
            "WARN": "-Wall",
            "COMPILE.c": "$(CC) $(CFLAGS) -c",
            "OUTPUT_OPTION": "-o $@",
        ]
        #expect(expand("$(CC) ${CFLAGS}", variables) == "clang -O2 -Wall")
        #expect(
            expand("$(COMPILE.c) $(OUTPUT_OPTION) $<", variables)
                == "clang -O2 -Wall -c -o dir/out.o a.c"
        )
    }

    /// @brief Undefined variables expand to nothing, as in make.
    @Test func undefinedVariablesAreEmpty() {
        #expect(
            expand("cc $(CPPFLAGS) ${TARGET_ARCH} -c", [:]) == "cc   -c"
        )
    }

    /// @brief Function calls and plain text are left untouched.
    @Test func leavesNonReferencesAlone() {
        #expect(
            expand("$(patsubst %.c,%.o,a.c) $$HOME 100%", [:])
                == "$(patsubst %.c,%.o,a.c) $$HOME 100%"
        )
    }

    /// @brief Circular definitions terminate.
    @Test func circularDefinitionsTerminate() {
        let variables = ["A": "$(B)", "B": "$(A)", "SELF": "x $(SELF)"]
        let circular = expand("$(A)", variables)
        #expect(circular == "$(A)" || circular == "$(B)")
        #expect(expand("$(SELF)", variables).hasPrefix("x x x"))
    }
}
