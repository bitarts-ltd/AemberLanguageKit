/**
    @file SwiftPack.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Aember's Swift language pack.
    @details
    - A language: Swift (.swift, swift scripts), with tree-sitter-swift
      compiled in (Grammar/src) and Aember's highlights query for it
      (Queries/).
    - A language server: sourcekit-lsp, found where Xcode or the
      Command Line Tools put it (/usr/bin, `xcrun --find`, Xcode's
      default toolchain). A Swift package needs nothing more; another
      project without xcode-build-server's buildServer.json is told to
      read the compilation database in .aember. It restarts when
      xcode-build-server is configured.
    - Build systems: Swift packages (100) and Xcode projects and
      workspaces (500), each configuring xcode-build-server when it is
      installed; an Xcode project without it gets a compilation
      database from xcodebuild's log (XcodeGenerator).
    - A package manager: SwiftPM (SwiftPMBackend), searching the Swift
      Package Index and the registries SwiftPM is set up with
      (SwiftPackageSearch), checking for updates with git tags and
      registry releases (SwiftPMChecks), and removing dependencies from
      Package.swift itself (SwiftPMManifestEditor, which parses with the
      tree-sitter runtime compiled into the pack, Grammar/runtime).

    Its text is in Strings.xcstrings, turned into PackStrings by
    Scripts/pack-strings.py.
*/

import Foundation
import AemberLanguageKit
#if canImport(TreeSitterSwift)
import TreeSitterSwift
#endif

/// @brief The Swift pack
final class SwiftPack: LanguagePack {

    let manifest = LanguagePackManifest(
        id: "swift",
        name: "Swift",
        version: LanguagePackVersion(1, 0, 0),
        summary: PackStrings.text("Swift files, sourcekit-lsp, Swift packages and Xcode projects"),
        author: "BitArts",
        homepage: URL(string: "https://bitarts.us/aember")
    )

    var languages: [LanguageDefinition] {
        [
            LanguageDefinition(
                id: "swift",
                displayName: "Swift",
                extensions: ["swift"],
                shebangInterpreters: ["swift"],
                lspLanguageID: "swift",
                lineComment: "//",
                blockComment: (start: "/*", end: "*/"),
                docComment: "///",
                grammar: Grammar(tree_sitter_swift, abiVersion: 15),
                queries: PackQueries.queries
            ),
        ]
    }

    var languageServers: [LanguageServerDefinition] {
        [
            LanguageServerDefinition(
                name: "sourcekit-lsp",
                executable: "sourcekit-lsp",
                languages: ["swift"],
                installGuidance: PackStrings.text("sourcekit-lsp is included with Xcode.\n\nInstall Xcode from the App Store, or install Command Line Tools:\n\n  xcode-select --install"),
                restartTriggers: [.buildServerConfigured],
                locate: { Self.locateSourceKitLSP() },
                projectArguments: { root, arguments in
                    Self.sourceKitArguments(arguments, for: root)
                }
            ),
        ]
    }

    var buildSystems: [BuildSystemProvider] {
        [
            BuildSystemProvider(SwiftPMBuildSystem.self, priority: 100),
            BuildSystemProvider(XcodeBuildSystem.self, priority: 500),
        ]
    }

    var packageBackends: [PackageBackend.Type] {
        [SwiftPMBackend.self]
    }

    // MARK: - sourcekit-lsp

    /// Where Xcode's default toolchain keeps sourcekit-lsp
    static let xcodeSourceKitLSP = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"

    /// @brief Finds sourcekit-lsp: /usr/bin's (the active toolchain's),
    /// else the one `xcrun --find` names, else Xcode's default
    /// toolchain's.
    /// @return Its URL, or nil when none is installed
    static func locateSourceKitLSP() -> URL? {
        let fileManager = FileManager.default
        if fileManager.isExecutableFile(atPath: "/usr/bin/sourcekit-lsp") {
            return URL(fileURLWithPath: "/usr/bin/sourcekit-lsp")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "sourcekit-lsp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0, !path.isEmpty, fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return fileManager.isExecutableFile(atPath: xcodeSourceKitLSP) ? URL(fileURLWithPath: xcodeSourceKitLSP) : nil
    }

    /// @brief sourcekit-lsp's arguments for a project: a Swift package,
    /// or a project xcode-build-server is configured for (buildServer.json),
    /// needs none; another reads the compilation database in .aember.
    /// @param arguments The server's arguments
    /// @param root The project's root
    /// @return The arguments
    static func sourceKitArguments(_ arguments: [String], for root: URL) -> [String] {
        let fileManager = FileManager.default
        let isPackage = fileManager.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
        let hasBuildServer = fileManager.fileExists(atPath: root.appendingPathComponent("buildServer.json").path)
        return isPackage || hasBuildServer ? arguments : arguments + ["--compilation-db-search-path=.aember"]
    }
}

// MARK: - What Aember Asks of the Backend

extension SwiftPMBackend {

    /// Package.swift and Package.resolved, watched for changes
    static let packageFileNames = ["Package.swift", "Package.resolved"]

    /// Packages are added with their sources, rule kinds and products
    static let addStyle = PackageAddStyle.swiftPackage

    /// The Swift Package Index's list, shared so it's read once
    static let packageIndex = SwiftPackageIndexSearch()

    /// @brief The Swift Package Index, for the Add Package sheet.
    /// @return The source
    static func searchSource() -> PackageSearchSource? {
        packageIndex
    }

    /// @brief Search, a git URL and a folder, and a registry identity
    /// when SwiftPM is set up with a registry.
    /// @param folder The package's folder
    /// @return The sources
    static func addSources(in folder: URL) -> [PackageAddSource] {
        SwiftRegistryConfiguration.load(for: folder).isEmpty ? [.search, .url, .folder] : PackageAddSource.allCases
    }

    /// @brief The Swift Package Index for a search or a URL (whose
    /// versions it knows), the registries for an identity, none for a
    /// folder.
    /// @param source The source
    /// @param folder The package's folder, for its registries
    /// @return The search source
    static func searchSource(for source: PackageAddSource, in folder: URL) -> PackageSearchSource? {
        switch source {
        case .search, .url:
            return packageIndex
        case .registry:
            return SwiftRegistrySearch(configuration: SwiftRegistryConfiguration.load(for: folder))
        case .folder:
            return nil
        }
    }
}

#if !SWIFT_PACKAGE
/// @brief Hands Aember the pack. Left out of SwiftPM builds, where the
/// pack is a module the SDK's tests link with the other packs.
/// @return The pack, retained
@_cdecl("aember_language_pack")
public func aemberLanguagePack() -> UnsafeMutableRawPointer {
    LanguagePackAPI.export(SwiftPack())
}
#endif
