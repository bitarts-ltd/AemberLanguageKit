// swift-tools-version: 6.0
/**
    @file Package.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief
    AemberLanguageKit: the SDK Aember's language packs are written with,
    and the packs Aember includes.
    @details
    The SDK is one dynamic library, built with library evolution, so a
    pack built against an older SDK still loads in a newer Aember:
    Aember embeds the framework and a pack links the copy Aember
    already loaded. Aember and its included packs build it from source;
    third-party packs link the published AemberLanguageKit.xcframework,
    which has the same install name.

    Each included pack in Packs/<Name> is also a target here, with its
    grammar as a C target and its tests, so `swift test` tests the
    packs' code; Aember builds the .aemberpack files themselves, one
    Xcode target each. The packs' entry points are left out of these
    builds (#if !SWIFT_PACKAGE), so they can link into one test bundle.
*/

import PackageDescription

/// @brief An included pack's targets: its grammar, its code and its
/// tests.
/// @param name The pack's folder in Packs/ (PHP)
/// @param grammarSources The grammar's C files, relative to Grammar/
/// @param grammarHeaderPaths Folders the grammar's sources include
/// headers from, relative to Grammar/
/// @param grammarExcludes Grammar files to leave out
/// @return The targets
func pack(_ name: String, grammarSources: [String], grammarHeaderPaths: [String], grammarExcludes: [String] = []) -> [Target] {
    let grammar = "TreeSitter\(name)"
    return [
        .target(
            name: grammar,
            path: "Packs/\(name)/Grammar",
            exclude: ["LICENSE", "SOURCE"] + grammarExcludes,
            sources: grammarSources,
            publicHeadersPath: "include",
            cSettings: grammarHeaderPaths.map { .headerSearchPath($0) } + [.unsafeFlags(["-Wno-unused-parameter"])]
        ),
        .target(
            name: "\(name)Pack",
            dependencies: ["AemberLanguageKit", .target(name: grammar)],
            path: "Packs/\(name)/Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "\(name)PackTests",
            dependencies: [.target(name: "\(name)Pack"), .target(name: "AemberLanguageKit"), .target(name: "PackTestSupport")],
            path: "Packs/\(name)/Tests",
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
}

let package = Package(
    name: "AemberLanguageKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AemberLanguageKit",
            type: .dynamic,
            targets: ["AemberLanguageKit"]
        )
    ],
    targets: [
        .target(
            name: "AemberLanguageKit",
            swiftSettings: [
                .unsafeFlags(["-enable-library-evolution"]),
                // The build and package code came from Aember, which is
                // in Swift 5 mode; strict concurrency comes once the
                // API settles
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "AemberLanguageKitTests",
            dependencies: ["AemberLanguageKit"]
        ),
        // What the packs' tests share; not a product
        .target(
            name: "PackTestSupport",
            dependencies: ["AemberLanguageKit"],
            path: "Tests/PackTestSupport",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
        + pack("PHP", grammarSources: ["php_only/src/parser.c", "php_only/src/scanner.c"], grammarHeaderPaths: ["php_only/src"])
        + pack("Python", grammarSources: ["src/parser.c", "src/scanner.c"], grammarHeaderPaths: ["src"])
        + pack("Rust", grammarSources: ["src/parser.c", "src/scanner.c"], grammarHeaderPaths: ["src"])
        + pack("TypeScript", grammarSources: ["typescript/src/parser.c", "typescript/src/scanner.c", "tsx/src/parser.c", "tsx/src/scanner.c", "javascript/src/parser.c", "javascript/src/scanner.c"], grammarHeaderPaths: ["typescript/src"], grammarExcludes: ["common/common.mak", "common/define-grammar.js", "javascript/LICENSE", "javascript/SOURCE"])
)
