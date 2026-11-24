/**
    @file PythonPack.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Aember's Python language pack.
    @details
    - A language: .py, .pyw and .pyi files and python scripts, with the
      tree-sitter-python grammar compiled in (Grammar/) and its
      highlights query (Queries/).
    - A language server: pylsp (python-lsp-server).
    - A build system: projects with pyproject.toml, setup.py or
      setup.cfg. They have no build step; tests run with pytest, which
      writes a JUnit report Aember reads.

    Its text is in Strings.xcstrings, turned into PackStrings by
    Scripts/pack-strings.py.
*/

import Foundation
import AemberLanguageKit
#if canImport(TreeSitterPython)
import TreeSitterPython
#endif

/// @brief The Python pack
final class PythonPack: LanguagePack {

    let manifest = LanguagePackManifest(
        id: "python",
        name: "Python",
        version: LanguagePackVersion(1, 0, 0),
        summary: PackStrings.text("Python files, pylsp and pytest"),
        author: "BitArts",
        homepage: URL(string: "https://bitarts.us/aember")
    )

    var languages: [LanguageDefinition] {
        [
            LanguageDefinition(
                id: "python",
                displayName: "Python",
                extensions: ["py", "pyw", "pyi"],
                shebangInterpreters: ["python"],
                lspLanguageID: "python",
                lineComment: "#",
                docComment: "\"\"\"",
                grammar: Grammar(tree_sitter_python, abiVersion: 15),
                queries: PackQueries.queries
            ),
        ]
    }

    var languageServers: [LanguageServerDefinition] {
        [
            LanguageServerDefinition(
                name: "pylsp",
                executable: "pylsp",
                languages: ["python"],
                installGuidance: PackStrings.text("Install pylsp for Python support:\n\n  brew install python-lsp-server\n\nOr via pip:\n\n  pip install python-lsp-server")
            ),
        ]
    }

    var buildSystems: [BuildSystemProvider] {
        [BuildSystemProvider(PythonBuildSystem.self, priority: 800)]
    }
}

/// @brief A Python project
struct PythonBuildSystem: DetectableBuildSystem {

    static let identifier = "python"

    var displayName: String {
        PackStrings.text("Python").localized
    }

    var buildFiles: [String] {
        ["pyproject.toml", "setup.py", "setup.cfg"]
    }

    static func detect(in projectRoot: URL) -> PythonBuildSystem? {
        let system = PythonBuildSystem()
        return system.buildFileURL(in: projectRoot) != nil ? system : nil
    }

    func command(for action: BuildAction, in projectRoot: URL, config: BuildProjectConfig?, filter: String?, outputDirectory: URL, context: any BuildSystemContext) throws -> BuildCommand {
        guard action == .test else {
            throw BuildCommandError.noCommand(PackStrings.text("Python projects have no build step; run the tests instead, or add \"build\" to .aember/build.json.").localized)
        }
        let report = outputDirectory.appendingPathComponent("junit.xml")
        var command = single("pytest", ["--junitxml=" + report.path] + (filter.map { ["-k", $0] } ?? []))
        command.junitReport = report
        return command
    }
}

#if !SWIFT_PACKAGE
/// @brief Hands Aember the pack. Left out of SwiftPM builds, where the
/// pack is a module the SDK's tests link with the other packs.
/// @return The pack, retained
@_cdecl("aember_language_pack")
public func aemberLanguagePack() -> UnsafeMutableRawPointer {
    LanguagePackAPI.export(PythonPack())
}
#endif
