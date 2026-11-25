/**
    @file MakeDatabaseParserTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for MakeDatabaseParser.
    @details
    Parses canned `make -p -n` output (trimmed from GNU Make 3.81) into
    variables, rules, pattern rules, and targets without commands, and
    splits a recursive make's output into one database per make with
    its directory, and
    runs the parser against a fake make shell script to cover arguments,
    environment, exit status handling, and output larger than a pipe
    buffer.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import CFamilyPack

/// @brief Canned `make -e -p -n` output shared by the Make tests.
enum MakeDatabaseFixture {

    /// Trimmed GNU Make 3.81 database for a Makefile with an explicit
    /// compile rule (a.o), a link rule (app), a phony target (all), an
    /// object built by the built-in %.o: %.c rule (b.o), and a
    /// cancelled pattern rule (%.out)
    static let output = """
        # GNU Make 3.81
        # Copyright (C) 2006  Free Software Foundation, Inc.

        # Make data base, printed on Mon Oct 26 08:55:56 2026

        # Variables

        # automatic
        <D = $(patsubst %/,%,$(dir $<))
        # makefile (from `Makefile', line 1)
        CC = clang
        # default
        OUTPUT_OPTION = -o $@
        # default
        COMPILE.c = $(CC) $(CFLAGS) $(CPPFLAGS) $(TARGET_ARCH) -c
        # makefile (from `Makefile', line 2)
        CFLAGS := -O2 -Wall
        # makefile (from `Makefile', line 3)
        OBJS = a.o b.o
        # environment
        _ = /usr/bin/make
        # variable set hash-table stats:
        # Load=167/1024=16%, Rehash=0, Collisions=7/200=4%

        # Directories

        # . (device 16777230, inode 123): 4 files, no impossibilities.

        # Implicit Rules

        %.out:

        %.o: %.c
        #  commands to execute (built-in):
        \t$(COMPILE.c) $(OUTPUT_OPTION) $<

        # 93 implicit rules, 5 (5.4%) terminal.

        # Files

        # Not a target:
        .web.p:
        #  Implicit rule search has not been done.
        #  commands to execute (built-in):
        \t$(TANGLE) $<

        a.o: a.c a.h
        #  Implicit rule search has not been done.
        #  File does not exist.
        # variable set hash-table stats:
        # Load=0/32=0%, Rehash=0, Collisions=0/0=0%
        #  commands to execute (from `Makefile', line 8):
        \t$(CC) $(CFLAGS) -c $< -o $@
        \t

        all: app
        #  Phony target (prerequisite of .PHONY).
        #  Implicit rule search has not been done.

        app: $(OBJS)
        #  Implicit rule search has not been done.
        #  commands to execute (from `Makefile', line 6):
        \t$(CC) -o $@ $^

        b.o: b.c
        #  Implicit rule search has been done.
        #  Implicit/static pattern stem: `b'
        # automatic
        # @ := b.o
        # automatic
        # < := b.c
        #  commands to execute (built-in):
        \t$(COMPILE.c) $(OUTPUT_OPTION) $<

        # Not a target:
        .PHONY: all
        #  Implicit rule search has not been done.

        # Finished Make data base on Mon Oct 26 08:55:56 2026

        ignored: after.c
        \tclang -c after.c
        """
}

@Suite("MakeDatabaseParser")
struct MakeDatabaseParserTests {

    /// @brief Variables from the variables section are collected.
    @Test func parsesVariables() {
        let variables = MakeDatabaseParser()
            .parseOutput(MakeDatabaseFixture.output).variables
        #expect(variables["CC"] == "clang")
        #expect(variables["CFLAGS"] == "-O2 -Wall")
        #expect(variables["OBJS"] == "a.o b.o")
        #expect(variables["OUTPUT_OPTION"] == "-o $@")
        #expect(variables["COMPILE.c"]
            == "$(CC) $(CFLAGS) $(CPPFLAGS) $(TARGET_ARCH) -c")
        #expect(variables["_"] == "/usr/bin/make")
    }

    /// @brief File entries with commands become rules; suffix rules,
    /// implicit rules, and anything after the end marker are not.
    @Test func parsesRulesWithCommands() throws {
        let rules = MakeDatabaseParser()
            .parseOutput(MakeDatabaseFixture.output).rules
        #expect(rules.map(\.target) == ["a.o", "app", "b.o"])

        let compile = try #require(rules.first)
        #expect(compile.dependencies == ["a.c", "a.h"])
        #expect(compile.commands == ["$(CC) $(CFLAGS) -c $< -o $@"])

        let link = try #require(rules.dropFirst().first)
        #expect(link.dependencies == ["$(OBJS)"])
        #expect(link.commands == ["$(CC) -o $@ $^"])

        let implicit = try #require(rules.last)
        #expect(implicit.commands == ["$(COMPILE.c) $(OUTPUT_OPTION) $<"])
    }

    /// @brief Pattern rules with commands come from the implicit rules
    /// section; ones without commands only cancel rules and are dropped.
    @Test func parsesPatternRules() throws {
        let database = MakeDatabaseParser()
            .parseOutput(MakeDatabaseFixture.output)
        let rule = try #require(database.patternRules.first)
        #expect(database.patternRules.count == 1)
        #expect(rule.target == "%.o")
        #expect(rule.dependencies == ["%.c"])
        #expect(rule.commands == ["$(COMPILE.c) $(OUTPUT_OPTION) $<"])
    }

    /// @brief File entries without commands are kept apart from rules.
    @Test func parsesTargetsWithoutCommands() throws {
        let database = MakeDatabaseParser()
            .parseOutput(MakeDatabaseFixture.output)
        let all = try #require(database.targetsWithoutCommands.first)
        #expect(database.targetsWithoutCommands.count == 1)
        #expect(all.target == "all")
        #expect(all.dependencies == ["app"])
        #expect(all.commands.isEmpty)
    }

    /// @brief A command-less entry does not swallow the section header
    /// or end marker after it.
    @Test func stopsAtHeadersAfterEntriesWithoutCommands() {
        let output = """
            # Implicit Rules
            %.o: %.c
            #  commands to execute (built-in):
            \tcc -c $<
            %.s:
            # Files
            b.o: b.h
            # Finished Make data base
            after.o: after.c
            \tcc -c after.c
            """
        let database = MakeDatabaseParser().parseOutput(output)
        #expect(database.patternRules.map(\.target) == ["%.o"])
        #expect(database.targetsWithoutCommands.map(\.target) == ["b.o"])
        #expect(database.rules.isEmpty)
    }

    /// @brief Double-colon rules keep their prerequisites.
    @Test func parsesDoubleColonRules() throws {
        let output = """
            # Implicit Rules
            %:: RCS/%,v
            #  commands to execute (built-in):
            \t$(CHECKOUT,v)
            """
        let database = MakeDatabaseParser().parseOutput(output)
        let rule = try #require(database.patternRules.first)
        #expect(rule.target == "%")
        #expect(rule.dependencies == ["RCS/%,v"])
    }

    /// @brief A rule with several command lines keeps them in order.
    @Test func parsesMultiLineCommands() throws {
        let output = """
            # Variables
            # Files
            gen.c: gen.y
            #  commands to execute (from 'Makefile', line 3):
            \tbison gen.y
            \tmv gen.tab.c gen.c

            """
        let rules = MakeDatabaseParser().parseOutput(output).rules
        let rule = try #require(rules.first)
        #expect(rules.count == 1)
        #expect(rule.dependencies == ["gen.y"])
        #expect(rule.commands == ["bison gen.y", "mv gen.tab.c gen.c"])
    }

    /// @brief A recursive make's output holds one database per make,
    /// each with its own rules and the directory its make ran in; what
    /// the makes print between them is not part of any.
    @Test func parsesEachDatabase() throws {
        let output = """
            # Make data base, printed on Tue Nov  3 23:07:26 2026
            # Variables
            CURDIR := /work/lib
            CFLAGS = -I../inc
            # Files
            lib.o: lib.c
            #  commands to execute (from `Makefile', line 4):
            \tcc $(CFLAGS) -c $< -o $@
            # Finished Make data base on Tue Nov  3 23:07:26 2026

            make -C app
            stray.o: stray.c
            \tcc -c stray.c

            # Make data base, printed on Tue Nov  3 23:07:26 2026
            # Variables
            CURDIR := /work
            # Files
            lib:
            #  commands to execute (from `Makefile', line 9):
            \t$(MAKE) -C $@
            # Finished Make data base on Tue Nov  3 23:07:26 2026
            """
        let databases = MakeDatabaseParser().parseDatabases(output)
        #expect(databases.count == 2)
        let lib = try #require(databases.first)
        let top = try #require(databases.last)
        #expect(lib.directory == "/work/lib")
        #expect(lib.variables["CFLAGS"] == "-I../inc")
        #expect(lib.rules.map(\.target) == ["lib.o"])
        #expect(top.directory == "/work")
        #expect(top.variables["CFLAGS"] == nil)
        #expect(top.rules.map(\.target) == ["lib"])
        #expect(MakeDatabaseParser().parseOutput(output).directory
            == "/work/lib")
    }

    /// @brief A database that doesn't set CURDIR names no directory.
    @Test func databaseWithoutCurdir() {
        let database = MakeDatabaseParser()
            .parseOutput(MakeDatabaseFixture.output)
        #expect(database.directory == nil)
    }

    /// @brief Output without the expected sections yields nothing.
    @Test(arguments: ["", "make: *** No targets.  Stop.\n", "a.o: a.c\n"])
    func emptyOrUnstructuredOutput(output: String) {
        let database = MakeDatabaseParser().parseOutput(output)
        #expect(database.variables.isEmpty)
        #expect(database.rules.isEmpty)
        #expect(database.patternRules.isEmpty)
        #expect(database.targetsWithoutCommands.isEmpty)
    }

    /// @brief make runs with -e -p -n, LC_ALL=C, and .aember/make-env.
    @Test func runsMakeWithDatabaseFlags() async throws {
        let fixture = try BuildSystemFixture()
        let record = fixture.url("make-record.txt").path
        let make = try fixture.writeScript("tools/make", """
            printf '%s\\n' "$@" "$LC_ALL" "$AEMBER_TEST_MAKE" "$(pwd -P)" \
                > "\(record)"
            printf '# Variables\\nX = 1\\n# Files\\n'
            """)
        try fixture.write(".aember/make-env", "AEMBER_TEST_MAKE=yes\n")
        let parser = MakeDatabaseParser(executablePath: make.path)
        let variables = try await parser.parse(projectURL: fixture.root)
            .first?.variables
        #expect(variables == ["X": "1"])
        let lines = try fixture.read("make-record.txt")
            .split(separator: "\n").map(String.init)
        #expect(Array(lines.prefix(5)) == ["-e", "-p", "-n", "C", "yes"])
        let workingDirectory = URL(fileURLWithPath: try #require(lines.last))
        #expect(workingDirectory.resolvingSymlinksInPath()
            == fixture.root.resolvingSymlinksInPath())
    }

    /// @brief Exit status 2 with a database dump is still parsed.
    @Test func toleratesExitStatusTwo() async throws {
        let fixture = try BuildSystemFixture()
        let make = try fixture.writeScript("tools/make", """
            printf '# Variables\\nX = 1\\n# Files\\n'
            echo "make: *** No rule to make target" >&2
            exit 2
            """)
        let parser = MakeDatabaseParser(executablePath: make.path)
        let variables = try await parser.parse(projectURL: fixture.root)
            .first?.variables
        #expect(variables?["X"] == "1")
    }

    /// @brief Failure with no output reports the exit status.
    @Test func failureWithoutOutputThrows() async throws {
        let fixture = try BuildSystemFixture()
        let make = try fixture.writeScript("tools/make", "exit 3")
        let parser = MakeDatabaseParser(executablePath: make.path)
        let error = await #expect(throws: CompilationDatabaseError.self) {
            _ = try await parser.parse(projectURL: fixture.root)
        }
        guard case .makeExecutionFailed(let status)? = error else {
            Issue.record("Unexpected error: \(String(describing: error))")
            return
        }
        #expect(status == 3)
    }

    /// @brief A database far larger than a pipe buffer is read fully.
    @Test(.timeLimit(.minutes(1)))
    func readsLargeDatabase() async throws {
        let fixture = try BuildSystemFixture()
        let make = try fixture.writeScript("tools/make", """
            echo "large stderr line" >&2
            printf '# Variables\\n'
            i=0
            while [ $i -lt 4000 ]; do
                printf 'VARIABLE_NUMBER_%04d = some reasonably long value\\n' $i
                i=$((i + 1))
            done
            printf '# Files\\n'
            """)
        let parser = MakeDatabaseParser(executablePath: make.path)
        let variables = try await parser.parse(projectURL: fixture.root)
            .first?.variables
        #expect(variables?.count == 4000)
    }
}
