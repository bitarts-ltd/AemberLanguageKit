/**
    @file TypeScriptBuildSystem.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief TypeScript projects as a build system.
    @details
    TypeScript/JavaScript projects (tsconfig.json or jsconfig.json),
    whose language server reads their own configuration, so they need
    no compilation database; they build with `npx tsc --noEmit` and
    test with `npm test [-- F]`.
*/

import Foundation
import AemberLanguageKit

/// @brief A TypeScript or JavaScript project
struct TypeScriptBuildSystem: DetectableBuildSystem {

    static let identifier = "typescript"

    var displayName: String {
        PackStrings.text("TypeScript").localized
    }

    var buildFiles: [String] {
        ["tsconfig.json", "jsconfig.json"]
    }

    static func detect(in projectRoot: URL) -> TypeScriptBuildSystem? {
        let system = TypeScriptBuildSystem()
        return system.buildFileURL(in: projectRoot) != nil ? system : nil
    }

    func command(for action: BuildAction, in projectRoot: URL, config: BuildProjectConfig?, filter: String?, outputDirectory: URL, context: any BuildSystemContext) throws -> BuildCommand {
        if action == .build {
            return single("npx", ["tsc", "--noEmit", "--pretty", "false"])
        }
        return single("npm", ["test"] + (filter.map { ["--", $0] } ?? []))
    }
}


