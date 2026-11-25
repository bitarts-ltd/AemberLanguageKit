/**
    @file PHPPack.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Aember's PHP language pack.
    @details
    The smallest of the included packs, and an example of each part a
    pack can give:

    - a language: .php and .phtml files and `#!/usr/bin/php` scripts,
      with the php_only tree-sitter grammar compiled in (Grammar/) and
      its highlights query (Queries/, embedded by
      Scripts/embed-queries.py);
    - a language server: intelephense, installed with npm, so found in
      npm's global folders as well as the usual ones;
    - a build system: Composer projects (composer.json), which have no
      build or test command of their own, so .aember/build.json gives
      them.

    Its text is in Strings.xcstrings, turned into PackStrings by
    Scripts/pack-strings.py.
*/

import Foundation
import AemberLanguageKit
#if canImport(TreeSitterPHP)
import TreeSitterPHP
#endif

/// @brief The PHP pack
final class PHPPack: LanguagePack {

    let manifest = LanguagePackManifest(
        id: "php",
        name: "PHP",
        version: LanguagePackVersion(1, 0, 0),
        summary: PackStrings.text("PHP files, intelephense and Composer projects"),
        author: "BitArts",
        homepage: URL(string: "https://bitarts.us/aember")
    )

    var languages: [LanguageDefinition] {
        [
            LanguageDefinition(
                id: "php",
                displayName: "PHP",
                extensions: ["php", "phtml"],
                shebangInterpreters: ["php"],
                lspLanguageID: "php",
                lineComment: "//",
                blockComment: (start: "/*", end: "*/"),
                docComment: "/**",
                grammar: Grammar(tree_sitter_php_only, abiVersion: 15),
                queries: PackQueries.queries,
                codeGraph: PackCodeGraph.php
            ),
        ]
    }

    var languageServers: [LanguageServerDefinition] {
        [
            LanguageServerDefinition(
                name: "intelephense",
                executable: "intelephense",
                arguments: ["--stdio"],
                languages: ["php"],
                searchDirectories: ToolLocations.npmGlobalDirectories(),
                installGuidance: PackStrings.text("Install intelephense for PHP support:\n\n  npm install -g intelephense")
            ),
        ]
    }

    var buildSystems: [BuildSystemProvider] {
        [BuildSystemProvider(ComposerBuildSystem.self, priority: 900)]
    }
}

/// @brief A PHP project with Composer
struct ComposerBuildSystem: DetectableBuildSystem {

    static let identifier = "php"

    var displayName: String {
        PackStrings.text("PHP/Composer").localized
    }

    var buildFiles: [String] {
        ["composer.json"]
    }

    static func detect(in projectRoot: URL) -> ComposerBuildSystem? {
        let system = ComposerBuildSystem()
        return system.buildFileURL(in: projectRoot) != nil ? system : nil
    }
}

#if !SWIFT_PACKAGE
/// @brief Hands Aember the pack. Left out of SwiftPM builds, where the
/// pack is a module the SDK's tests link with the other packs.
/// @return The pack, retained
@_cdecl("aember_language_pack")
public func aemberLanguagePack() -> UnsafeMutableRawPointer {
    LanguagePackAPI.export(PHPPack())
}
#endif
