/**
    @file ExamplePack.swift
    @brief A language pack to start from.
    @details
    Copy the Template folder, rename it for your language (ZigPack),
    and change "example" here and in Info.plist to your pack's
    identifier. This pack gives one language: files ending in .example,
    with # comments. The parts after it show what else a pack can give;
    the included packs in Packs/ are complete examples of each.
*/

import Foundation
import AemberLanguageKit
// With a grammar in Grammar/, SwiftPM's builds (swift test) see it as a
// module; build-pack.sh's see it through the bridging header:
//
// #if canImport(TreeSitterGrammar)
// import TreeSitterGrammar
// #endif

/// @brief The pack
final class ExamplePack: LanguagePack {

    /// Who made it and what it is. The id and version must match the
    /// Info.plist's AemberPackID and CFBundleShortVersionString.
    let manifest = LanguagePackManifest(
        id: "example",
        name: "Example",
        version: LanguagePackVersion(1, 0, 0),
        summary: "Example files",
        author: "Your Name",
        homepage: URL(string: "https://example.com")
    )

    /// The languages it defines
    var languages: [LanguageDefinition] {
        [
            LanguageDefinition(
                id: "example",
                displayName: LocalizedText("Example", translations: ["fr": "Exemple", "de": "Beispiel"]),
                extensions: ["example"],
                shebangInterpreters: ["example"],
                lspLanguageID: "example",
                lineComment: "#"
                // To highlight the language, add its tree-sitter grammar
                // with Scripts/vendor-grammar.py, embed its queries with
                // Scripts/embed-queries.py, and give them here:
                //
                // grammar: Grammar(tree_sitter_example, abiVersion: 15),
                // queries: PackQueries.queries
            ),
        ]
    }

    /// The language servers it runs. Aember starts one when a file of
    /// its languages opens, and shows installGuidance when it can't
    /// find the executable.
    var languageServers: [LanguageServerDefinition] {
        [
            LanguageServerDefinition(
                name: "example-language-server",
                executable: "example-language-server",
                arguments: ["--stdio"],
                languages: ["example"],
                installGuidance: "Install example-language-server for Example support."
            ),
        ]
    }

    /// The build systems it detects; see BuildSystem.swift and the
    /// PHP pack's ComposerBuildSystem for a small one
    var buildSystems: [BuildSystemProvider] {
        []
    }

    /// The package managers it reads and changes; see
    /// PackageBackend.swift and the Rust pack's Cargo backend
    var packageBackends: [PackageBackend.Type] {
        []
    }

    /// @brief Called when Aember enables the pack, before it asks for
    /// the pack's contributions.
    /// @param context What Aember gives the pack: its version, a log,
    /// settings, and finding commands
    /// @return None
    func activate(context: any LanguagePackContext) {
        context.log("Example pack enabled")
    }
}

#if !SWIFT_PACKAGE
/// @brief Hands Aember the pack: the one function a pack exports.
/// @return The pack, retained
@_cdecl("aember_language_pack")
public func aemberLanguagePack() -> UnsafeMutableRawPointer {
    LanguagePackAPI.export(ExamplePack())
}
#endif
