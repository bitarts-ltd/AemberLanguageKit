/**
    @file MakeCommandFilterTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Tests for MakeCommandFilter.
    @details
    Classifies expanded Make recipe lines as compilation or not, and
    extracts the source and output files from compile commands.
*/

import Testing
import AemberLanguageKit
import PackTestSupport
@testable import CFamilyPack

@Suite("MakeCommandFilter")
struct MakeCommandFilterTests {

    private let filter = MakeCommandFilter()

    /// @brief Compiler invocations with -c are compilation commands.
    @Test(arguments: [
        "gcc -c main.c -o main.o",
        "clang -O2 -Wall -c src/a.c -o build/a.o",
        "/usr/bin/clang++ -std=c++20 -c x.cpp",
        "cc -O2   -c -o b.o b.c",
        "arm-none-eabi-gcc -mcpu=cortex-m4 -c startup.c",
        "swiftc -c a.swift b.swift",
        "gcc -DMODE=bar -c a.c -o a.o",
        "gcc -I/usr/include/sugar -c a.c",
        "clang -c\tmain.c",
    ])
    func recognizesCompilation(command: String) {
        #expect(filter.isCompilationCommand(command))
    }

    /// @brief Links, archives, and non-compiler commands are rejected.
    @Test(arguments: [
        "gcc -o app main.o util.o",
        "clang main.o -lm -o app",
        "ar rcs libfoo.a a.o b.o",
        "/usr/bin/ar rcs libfoo.a a.o",
        "ranlib libfoo.a",
        // Archive commands that mention a compiler name and -c
        "cd lib && ar -c rcs libgcc.a x.o",
        "/usr/bin/ar -c r libclang.a x.o",
        "gcc -c a.c; ranlib libgcc.a",
        "echo compiling -c things",
        "mv -f lex.yy.c scanner.c",
        "",
    ])
    func rejectsNonCompilation(command: String) {
        #expect(!filter.isCompilationCommand(command))
    }

    /// @brief The source is the first source-file argument that is not
    /// the -o value; the output is the -o value.
    @Test(arguments: [
        ("gcc -c main.c -o main.o", "main.c", "main.o"),
        ("cc -O2 -c -o b.o b.c", "b.c", "b.o"),
        ("clang++ -c src/x.cpp", "src/x.cpp", nil),
        ("clang -c weird.C -o weird.o", "weird.C", "weird.o"),
        ("c++ -c k.c++ -o k.o", "k.c++", "k.o"),
        ("clang -fobjc-arc -c View.m -o View.o", "View.m", "View.o"),
        ("clang -c a.mm", "a.mm", nil),
        ("swiftc -c a.swift b.swift", "a.swift", nil),
        ("gcc -o out.c -c real.c", "real.c", "out.c"),
    ] as [(String, String, String?)])
    func extractsSourceAndOutput(
        command: String,
        source: String,
        output: String?
    ) throws {
        let extracted = try #require(
            filter.extractCompileCommand(
                from: command,
                workingDirectory: "/proj"
            )
        )
        #expect(extracted.file == source)
        #expect(extracted.output == output)
        #expect(extracted.directory == "/proj")
        #expect(extracted.command == command)
        #expect(extracted.arguments == nil)
    }

    /// @brief Commands without a source file yield nil.
    @Test(arguments: [
        "gcc -c -o x.o",
        "gcc -c header.h",
        "gcc -c -DFILE=a.c",
    ])
    func noSourceFile(command: String) {
        #expect(
            filter.extractCompileCommand(
                from: command,
                workingDirectory: "/proj"
            ) == nil
        )
    }
}
