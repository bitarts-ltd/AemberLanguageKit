/**
    @file CFamilyPack.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Aember's C, C++ and Objective-C language pack.
    @details
    - Languages: C (.c, .h, and Objective-C's .m) and C++ (.cpp, .cc,
      .cxx, .hpp, .hh, .hxx, and Objective-C++'s .mm), with the
      tree-sitter-c and tree-sitter-cpp grammars compiled in (Grammar/)
      and Aember's highlights queries for them (Queries/). Objective-C
      files are highlighted as C and C++, and the language server is
      told they are objective-c and objective-cpp.
    - A language server: clangd, one per project for all four
      languages (serverKey "c-family"), reading the compilation
      database Aember keeps in the project's .aember folder, and
      restarted when it is written again.
    - Build systems: CMake (300), Ninja (400) and Make (600), each
      writing a compilation database for clangd with its generator
      (CMakeGenerator, NinjaGenerator, MakeGenerator and Make/).
      Xcode projects, which build Objective-C too, are the Swift
      pack's.

    Its text is in Strings.xcstrings, turned into PackStrings by
    Scripts/pack-strings.py.
*/

import Foundation
import AemberLanguageKit
#if canImport(TreeSitterCFamily)
import TreeSitterCFamily
#endif

/// @brief The C Family pack
final class CFamilyPack: LanguagePack {

    /// The LSP languages clangd serves
    static let clangdLanguages = ["c", "cpp", "objective-c", "objective-cpp"]

    /// The key they share one clangd under
    static let clangdServerKey = "c-family"

    let manifest = LanguagePackManifest(
        id: "c-family",
        name: "C Family",
        version: LanguagePackVersion(1, 0, 0),
        summary: PackStrings.text("C, C++ and Objective-C files, clangd, and CMake, Ninja and Make builds"),
        author: "BitArts",
        homepage: URL(string: "https://bitarts.us/aember")
    )

    var languages: [LanguageDefinition] {
        [
            LanguageDefinition(
                id: "c",
                displayName: "C",
                extensions: ["c", "h", "m"],
                lspLanguageID: "c",
                lspLanguageIDsByExtension: ["m": "objective-c"],
                lineComment: "//",
                blockComment: (start: "/*", end: "*/"),
                docComment: "/**",
                grammar: Grammar(tree_sitter_c, abiVersion: 15),
                queries: PackQueries.c
            ),
            LanguageDefinition(
                id: "cpp",
                displayName: "C++",
                extensions: ["cpp", "cc", "cxx", "hpp", "hh", "hxx", "mm"],
                lspLanguageID: "cpp",
                lspLanguageIDsByExtension: ["mm": "objective-cpp"],
                lineComment: "//",
                blockComment: (start: "/*", end: "*/"),
                docComment: "/**",
                grammar: Grammar(tree_sitter_cpp, abiVersion: 15),
                queries: PackQueries.cpp
            ),
        ]
    }

    var languageServers: [LanguageServerDefinition] {
        [
            LanguageServerDefinition(
                name: "clangd",
                executable: "clangd",
                arguments: ["--background-index", "--clang-tidy"],
                languages: Self.clangdLanguages,
                serverKey: Self.clangdServerKey,
                installGuidance: PackStrings.text("Install clangd for C/C++/Objective-C support:\n\n  brew install llvm\n\nOr install Xcode Command Line Tools:\n\n  xcode-select --install"),
                restartTriggers: [.compilationDatabaseChanged],
                projectArguments: { root, arguments in
                    arguments + ["--compile-commands-dir=" + root.appendingPathComponent(".aember").path]
                },
                prepare: { root in
                    Self.touchCompilationDatabase(in: root)
                }
            ),
        ]
    }

    var buildSystems: [BuildSystemProvider] {
        [
            BuildSystemProvider(CMakeBuildSystem.self, priority: 300),
            BuildSystemProvider(NinjaBuildSystem.self, priority: 400),
            BuildSystemProvider(MakeBuildSystem.self, priority: 600),
        ]
    }

    /// @brief Touches the project's compile_commands.json before clangd
    /// starts.
    /// @details
    /// clangd doesn't always read compile_commands.json properly on a
    /// fresh start, but does once the file has changed; touching it
    /// works around that.
    /// @param root The project's root
    /// @return None
    static func touchCompilationDatabase(in root: URL) {
        let path = root.appendingPathComponent(".aember").appendingPathComponent("compile_commands.json").path
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
        }
    }
}

#if !SWIFT_PACKAGE
/// @brief Hands Aember the pack. Left out of SwiftPM builds, where the
/// pack is a module the SDK's tests link with the other packs.
/// @return The pack, retained
@_cdecl("aember_language_pack")
public func aemberLanguagePack() -> UnsafeMutableRawPointer {
    LanguagePackAPI.export(CFamilyPack())
}
#endif
