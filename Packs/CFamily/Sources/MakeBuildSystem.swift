/**
    @file MakeBuildSystem.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief GNU Make as a build system.
    @details
    A project with a Makefile, makefile or GNUmakefile in its root. It
    builds with `make` and tests with `make test`, which takes no
    filter. MakeGenerator writes compile_commands.json from make's
    database.
*/

import Foundation
import AemberLanguageKit

/// @brief A Make project
struct MakeBuildSystem: DetectableBuildSystem {

    static let identifier = "make"

    var displayName: String {
        PackStrings.text("Make").localized
    }

    var buildFiles: [String] {
        ["Makefile", "makefile", "GNUmakefile"]
    }

    static func detect(in projectRoot: URL) -> MakeBuildSystem? {
        let system = MakeBuildSystem()
        return system.buildFileURL(in: projectRoot) != nil ? system : nil
    }

    func command(for action: BuildAction, in projectRoot: URL, config: BuildProjectConfig?, filter: String?, outputDirectory: URL, context: any BuildSystemContext) throws -> BuildCommand {
        if filter != nil {
            throw BuildCommandError.badFilter(PackStrings.text("make test takes no filter; add \"test\" and \"testFilter\" to .aember/build.json to pass one.").localized)
        }
        return single("make", action == .build ? [] : ["test"])
    }

    func compilationDatabase(for projectURL: URL, context: any BuildSystemContext, onOutput: ((String) -> Void)?) async throws -> CompilationDatabaseOutput {
        .generated(try await MakeGenerator(executablePath: context.toolPath("make")).generate(projectURL: projectURL, onOutput: onOutput))
    }
}
