/**
    @file MakeGeneratorTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Tests for MakeGenerator.
    @details
    Runs the generator against a fake make shell script that prints
    canned `make -p` output, then checks the compile_commands.json it
    writes: explicit and built-in compile rules are included with
    expanded commands, pattern rules are applied to targets listed
    without commands, link rules are not, a recursive make's sub-makes'
    commands keep their own flags and directories, and metadata is not
    encoded.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import CFamilyPack

@Suite("MakeGenerator")
struct MakeGeneratorTests {

    /// @brief Create a fixture project whose fake make prints a dump.
    /// @param database The canned `make -p` output
    /// @return The fixture and a generator that runs the fake
    private func makeProject(
        database: String
    ) throws -> (BuildSystemFixture, MakeGenerator) {
        let fixture = try BuildSystemFixture()
        try fixture.write("Makefile", "all:\n")
        return try makeProject(in: fixture, database: database)
    }

    /// @brief Give a fixture project a fake make that prints a dump.
    /// @param fixture The project
    /// @param database The canned `make -p` output
    /// @return The fixture and a generator that runs the fake
    private func makeProject(
        in fixture: BuildSystemFixture,
        database: String
    ) throws -> (BuildSystemFixture, MakeGenerator) {
        let dump = try fixture.write("make-p.txt", database)
        let make = try fixture.writeScript(
            "tools/make",
            "cat \"\(dump.path)\""
        )
        return (fixture, MakeGenerator(executablePath: make.path))
    }

    /// @brief Compile rules become compile commands in .aember.
    @Test func generatesDatabase() async throws {
        let (fixture, generator) = try makeProject(
            database: MakeDatabaseFixture.output
        )
        let output = OutputLines()
        let result = try await generator.generate(
            projectURL: fixture.root,
            onOutput: output.append
        )
        #expect(result == fixture.url(".aember/compile_commands.json"))

        let data = try Data(contentsOf: result)
        let commands = try JSONDecoder().decode(
            [CompileCommand].self,
            from: data
        )
        #expect(commands.map(\.file) == ["a.c", "b.c"])
        #expect(commands.map(\.output) == ["a.o", "b.o"])
        #expect(commands.allSatisfy { $0.directory == fixture.root.path })
        #expect(commands.first?.command == "clang -O2 -Wall -c a.c -o a.o")
        #expect(commands.last?.command == "clang -O2 -Wall   -c -o b.o b.c")

        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("metadata"))
        #expect(!text.contains("buildSystem"))

        #expect(output.lines.first == "Parsing Makefile database…")
        #expect(output.lines.contains("Extracted 2 compilation commands"))
    }

    /// @brief Objects make never searched implicit rules for, because
    /// the default goal does not need them, are compiled by the pattern
    /// rule make would use.
    @Test func compilesTargetsWithoutCommands() async throws {
        let (fixture, generator) = try makeProject(database: """
            # Variables
            CC = clang
            COMPILE.c = $(CC) -c
            # Implicit Rules
            obj/%.o: src/%.c
            #  commands to execute (from `Makefile', line 8):
            \t$(CC) -O0 -c $< -o $@
            %.o: %.c
            #  commands to execute (built-in):
            \t$(COMPILE.c) -o $@ $<
            # Files
            src/t.o: t.h
            #  Implicit rule search has not been done.

            obj/u.o:
            #  Implicit rule search has not been done.

            gen.o:
            #  Implicit rule search has not been done.

            # Not a target:
            gen.c:
            #  Implicit rule search has not been done.

            missing.o:
            #  Implicit rule search has not been done.

            tests: src/t.o obj/u.o gen.o missing.o
            #  Implicit rule search has not been done.
            # Finished Make data base
            """)
        try fixture.write("src/t.c")
        try fixture.write("src/u.c")
        let result = try await generator.generate(projectURL: fixture.root)

        let commands = try JSONDecoder().decode(
            [CompileCommand].self,
            from: Data(contentsOf: result)
        )
        #expect(commands.map(\.command) == [
            "clang -c -o src/t.o src/t.c",
            "clang -O0 -c src/u.c -o obj/u.o",
            "clang -c -o gen.o gen.c",
        ])
    }

    /// @brief A recursive Makefile's sub-makes' compile commands are
    /// taken with their own flags and directories, not the top-level
    /// make's.
    @Test func compilesSubMakesInTheirDirectories() async throws {
        let fixture = try BuildSystemFixture()
        try fixture.write("Makefile", "all:\n")
        try fixture.write("queue/queue.c")
        let queue = fixture.url("queue").path
        let (_, generator) = try makeProject(
            in: fixture,
            database: """
                # Make data base, printed on Tue Nov  3 23:07:26 2026
                # Variables
                CURDIR := \(queue)
                CC = gcc
                CFLAGS = -Wall -I../copt
                # Implicit Rules
                %.o: %.c
                #  commands to execute (built-in):
                \t$(CC) $(CFLAGS) -c $< -o $@
                # Files
                demo.o: demo.c
                #  commands to execute (from `Makefile', line 5):
                \t$(CC) $(CFLAGS) -c $< -o $@

                queue.o:
                #  Implicit rule search has not been done.
                # Finished Make data base on Tue Nov  3 23:07:26 2026

                gcc -Wall -I../copt -c demo.c -o demo.o

                # Make data base, printed on Tue Nov  3 23:07:26 2026
                # Variables
                CURDIR := \(fixture.root.path)
                MAKE = make
                # Implicit Rules
                %.o: %.c
                #  commands to execute (built-in):
                \tcc -c $< -o $@
                # Files
                queue:
                #  commands to execute (from `Makefile', line 9):
                \t$(MAKE) -C $@

                alloc.o:
                #  Implicit rule search has not been done.
                # Finished Make data base on Tue Nov  3 23:07:26 2026
                """
        )
        let result = try await generator.generate(projectURL: fixture.root)

        let commands = try JSONDecoder().decode(
            [CompileCommand].self,
            from: Data(contentsOf: result)
        )
        #expect(commands.map(\.file) == ["demo.c", "queue.c"])
        #expect(commands.allSatisfy { $0.directory == queue })
        #expect(commands.allSatisfy { $0.command?.contains("-I../copt") == true })
    }

    /// @brief A database without compile rules is an error.
    @Test func noCompilationCommands() async throws {
        let (fixture, generator) = try makeProject(database: """
            # Variables
            CC = cc
            # Files
            app: main.o
            #  commands to execute (from `Makefile', line 2):
            \t$(CC) -o $@ $^
            """)
        let error = await #expect(throws: CompilationDatabaseError.self) {
            _ = try await generator.generate(projectURL: fixture.root)
        }
        guard case .noCompilationCommands? = error else {
            Issue.record("Unexpected error: \(String(describing: error))")
            return
        }
        #expect(!fixture.exists(".aember/compile_commands.json"))
    }
}
