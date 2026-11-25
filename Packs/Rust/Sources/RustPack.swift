/**
    @file RustPack.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Aember's Rust language pack.
    @details
    - A language: .rs files, with the tree-sitter-rust grammar compiled
      in (Grammar/) and its highlights query (Queries/).
    - A language server: rust-analyzer, often installed by rustup in
      ~/.cargo/bin.
    - A build system: Cargo packages and workspaces (Cargo.toml),
      built with `cargo build --message-format=json` and tested with
      `cargo test [F]` (CargoBuildSystem).
    - A package manager: Cargo (CargoBackend), reading Cargo.toml with
      `cargo metadata` and Cargo.lock, changing them with cargo add,
      remove and update, searching crates.io (CratesIOSearch) and
      checking for updates and advisories (CargoChecks).

    Its text is in Strings.xcstrings, turned into PackStrings by
    Scripts/pack-strings.py.
*/

import Foundation
import AemberLanguageKit
#if canImport(TreeSitterRust)
import TreeSitterRust
#endif

/// @brief The Rust pack
final class RustPack: LanguagePack {

    let manifest = LanguagePackManifest(
        id: "rust",
        name: "Rust",
        version: LanguagePackVersion(1, 0, 0),
        summary: PackStrings.text("Rust files, rust-analyzer, Cargo builds and crates"),
        author: "BitArts",
        homepage: URL(string: "https://bitarts.us/aember")
    )

    var languages: [LanguageDefinition] {
        [
            LanguageDefinition(
                id: "rust",
                displayName: "Rust",
                extensions: ["rs"],
                lspLanguageID: "rust",
                lineComment: "//",
                blockComment: (start: "/*", end: "*/"),
                docComment: "///",
                grammar: Grammar(tree_sitter_rust, abiVersion: 15),
                queries: PackQueries.queries
            ),
        ]
    }

    var languageServers: [LanguageServerDefinition] {
        [
            LanguageServerDefinition(
                name: "rust-analyzer",
                executable: "rust-analyzer",
                languages: ["rust"],
                searchDirectories: [ToolLocations.cargoDirectory],
                installGuidance: PackStrings.text("Install rust-analyzer for Rust support:\n\n  brew install rust-analyzer\n\nOr via rustup:\n\n  rustup component add rust-analyzer")
            ),
        ]
    }

    var buildSystems: [BuildSystemProvider] {
        [BuildSystemProvider(CargoBuildSystem.self, priority: 200)]
    }

    var packageBackends: [PackageBackend.Type] {
        [CargoBackend.self]
    }
}

#if !SWIFT_PACKAGE
/// @brief Hands Aember the pack. Left out of SwiftPM builds, where the
/// pack is a module the SDK's tests link with the other packs.
/// @return The pack, retained
@_cdecl("aember_language_pack")
public func aemberLanguagePack() -> UnsafeMutableRawPointer {
    LanguagePackAPI.export(RustPack())
}
#endif
