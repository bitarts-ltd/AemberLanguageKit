/**
    @file TypeScriptPack.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Aember's TypeScript and JavaScript language pack.
    @details
    - Languages: JavaScript (.js, .mjs, .cjs, .jsx, node scripts),
      TypeScript (.ts) and TSX (.tsx), with their tree-sitter grammars
      compiled in (Grammar/: tree-sitter-javascript, and
      tree-sitter-typescript's typescript and tsx). TypeScript's and
      TSX's highlights only add to JavaScript's, as upstream ships
      them, so they inherit it.
    - Language servers: TypeScript 7's native tsc (`tsc --lsp
      --stdio`) first, accepted only when `tsc --version` says 7 or
      later; else typescript-language-server, which needs TypeScript
      5 or 6's tsserver. Both are found in npm's global folders too.
    - A build system: projects with tsconfig.json or jsconfig.json,
      built with `npx tsc --noEmit` and tested with `npm test [-- F]`.
    - Package managers: npm, pnpm and Yarn, one per package.json as
      its packageManager field or lockfile says (NodePackageManager),
      searching the npm registry and checking for updates and
      advisories (NodePackageChecks).

    Its text is in Strings.xcstrings, turned into PackStrings by
    Scripts/pack-strings.py.
*/

import Foundation
import AemberLanguageKit
#if canImport(TreeSitterTypeScript)
import TreeSitterTypeScript
#endif

/// @brief The TypeScript pack
final class TypeScriptPack: LanguagePack {

    /// The LSP languages both servers serve
    static let serverLanguages = ["typescript", "javascript", "typescriptreact", "javascriptreact"]

    let manifest = LanguagePackManifest(
        id: "typescript",
        name: "TypeScript",
        version: LanguagePackVersion(1, 0, 0),
        summary: PackStrings.text("TypeScript and JavaScript files, their language servers, and npm, pnpm and Yarn"),
        author: "BitArts",
        homepage: URL(string: "https://bitarts.us/aember")
    )

    var languages: [LanguageDefinition] {
        [
            LanguageDefinition(
                id: "javascript",
                displayName: "JavaScript",
                extensions: ["js", "mjs", "cjs", "jsx"],
                shebangInterpreters: ["node"],
                lspLanguageID: "javascript",
                lspLanguageIDsByExtension: ["jsx": "javascriptreact"],
                lineComment: "//",
                blockComment: (start: "/*", end: "*/"),
                docComment: "/**",
                grammar: Grammar(tree_sitter_javascript, abiVersion: 14),
                queries: PackQueries.javascript
            ),
            LanguageDefinition(
                id: "typescript",
                displayName: "TypeScript",
                extensions: ["ts"],
                lspLanguageID: "typescript",
                lineComment: "//",
                blockComment: (start: "/*", end: "*/"),
                docComment: "/**",
                grammar: Grammar(tree_sitter_typescript, abiVersion: 15),
                queries: PackQueries.typescript,
                inheritsQueriesFrom: "javascript"
            ),
            LanguageDefinition(
                id: "tsx",
                displayName: "TSX",
                extensions: ["tsx"],
                lspLanguageID: "typescriptreact",
                lineComment: "//",
                blockComment: (start: "/*", end: "*/"),
                docComment: "/**",
                grammar: Grammar(tree_sitter_tsx, abiVersion: 14),
                queries: PackQueries.tsx,
                inheritsQueriesFrom: "javascript"
            ),
        ]
    }

    var languageServers: [LanguageServerDefinition] {
        let npm = ToolLocations.npmGlobalDirectories()
        return [
            LanguageServerDefinition(
                name: "tsc",
                executable: "tsc",
                arguments: ["--lsp", "--stdio"],
                languages: Self.serverLanguages,
                priority: 0,
                searchDirectories: npm,
                installGuidance: PackStrings.text("Install TypeScript 7 or later for TypeScript/JavaScript support; its tsc includes a language server:\n\n  brew install typescript\n\nOr via npm:\n\n  npm install -g typescript"),
                accepts: { Self.isNativeLanguageServer($0) }
            ),
            LanguageServerDefinition(
                name: "typescript-language-server",
                executable: "typescript-language-server",
                arguments: ["--stdio"],
                languages: Self.serverLanguages,
                priority: 10,
                searchDirectories: npm,
                installGuidance: PackStrings.text("Install typescript-language-server with TypeScript 5 or 6, which provide the tsserver it needs:\n\n  npm install -g typescript-language-server typescript@6\n\nOr install TypeScript 7 or later, whose tsc includes a language server:\n\n  brew install typescript")
            ),
        ]
    }

    var buildSystems: [BuildSystemProvider] {
        [BuildSystemProvider(TypeScriptBuildSystem.self, priority: 700)]
    }

    var packageBackends: [PackageBackend.Type] {
        [NPMBackend.self, PNPMBackend.self, YarnBackend.self]
    }

    // MARK: - tsc

    /// The first TypeScript major version whose tsc has --lsp
    static let minimumNativeTypeScriptVersion = 7

    /// @brief Whether a tsc found can serve LSP: TypeScript 7 and later
    /// have a native language server (tsc --lsp), and earlier versions
    /// don't, so an older one counts as not installed and
    /// typescript-language-server is tried instead.
    /// @param url The tsc found
    /// @return True when `tsc --version` says 7 or later
    static func isNativeLanguageServer(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        // tsc is a Node script (#!/usr/bin/env node): run it with its
        // folder on PATH, as the server itself runs
        var environment = ProcessInfo.processInfo.environment
        let folder = url.deletingLastPathComponent().path
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = path.split(separator: ":").contains { $0 == folder } ? path : folder + ":" + path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // A process that never ran has no termination status to read
        guard (try? process.run()) != nil else {
            return false
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0, let major = typeScriptMajorVersion(from: output) else {
            return false
        }
        return major >= minimumNativeTypeScriptVersion
    }

    /// @brief Parse the major version from `tsc --version` output.
    /// @param output The output, e.g. "Version 7.0.2"
    /// @return The major version, or nil if output has none
    static func typeScriptMajorVersion(from output: String) -> Int? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("Version ") else { return nil }
        let version = text.dropFirst("Version ".count)
        let major = version.prefix { $0.isNumber }
        guard !major.isEmpty, version.dropFirst(major.count).first == "." else {
            return nil
        }
        return Int(major)
    }
}

// MARK: - What Aember Asks of the Backends

extension NPMBackend {

    /// package.json and package-lock.json, watched for changes
    static let packageFileNames = ["package.json", "package-lock.json"]

    /// Normal, dev and optional dependencies
    static let dependencyKinds: [DependencyKind] = [.normal, .dev, .optional]

    /// npm reads a bare version as exactly it
    static let bareVersionIsExact = true

    /// @brief The npm registry, for the Add Package sheet.
    /// @return The source
    static func searchSource() -> PackageSearchSource? {
        NPMRegistrySearch()
    }
}

extension PNPMBackend {

    /// package.json, pnpm-lock.yaml and pnpm-workspace.yaml
    static let packageFileNames = ["package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml"]

    /// Normal, dev and optional dependencies
    static let dependencyKinds: [DependencyKind] = [.normal, .dev, .optional]

    /// pnpm reads a bare version as exactly it
    static let bareVersionIsExact = true

    /// @brief The npm registry, for the Add Package sheet.
    /// @return The source
    static func searchSource() -> PackageSearchSource? {
        NPMRegistrySearch()
    }
}

extension YarnBackend {

    /// package.json and yarn.lock
    static let packageFileNames = ["package.json", "yarn.lock"]

    /// Normal, dev and optional dependencies
    static let dependencyKinds: [DependencyKind] = [.normal, .dev, .optional]

    /// Yarn reads a bare version as exactly it
    static let bareVersionIsExact = true

    /// @brief The npm registry, for the Add Package sheet.
    /// @return The source
    static func searchSource() -> PackageSearchSource? {
        NPMRegistrySearch()
    }
}

#if !SWIFT_PACKAGE
/// @brief Hands Aember the pack. Left out of SwiftPM builds, where the
/// pack is a module the SDK's tests link with the other packs.
/// @return The pack, retained
@_cdecl("aember_language_pack")
public func aemberLanguagePack() -> UnsafeMutableRawPointer {
    LanguagePackAPI.export(TypeScriptPack())
}
#endif
