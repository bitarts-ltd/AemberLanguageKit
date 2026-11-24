/**
    @file SwiftPMBuildSystem.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Swift Package Manager as a build system.
    @details
    A project with a Package.swift in its root. It builds with `swift
    build` and tests with `swift test [--filter F]`. sourcekit-lsp reads
    Package.swift itself; when xcode-build-server is installed and an
    Xcode project or workspace sits beside the package, it is
    configured for its fuller index.
*/

import Foundation
import AemberLanguageKit

/// @brief A Swift package
struct SwiftPMBuildSystem: DetectableBuildSystem {

    static let identifier = "swiftpm"

    var displayName: String {
        PackStrings.text("Swift Package Manager").localized
    }

    var buildFiles: [String] {
        ["Package.swift"]
    }

    static func detect(in projectRoot: URL) -> SwiftPMBuildSystem? {
        let system = SwiftPMBuildSystem()
        return system.buildFileURL(in: projectRoot) != nil ? system : nil
    }

    func command(for action: BuildAction, in projectRoot: URL, config: BuildProjectConfig?, filter: String?, outputDirectory: URL, context: any BuildSystemContext) throws -> BuildCommand {
        if action == .build {
            return single("swift", ["build"])
        }
        return single("swift", ["test"] + (filter.map { ["--filter", $0] } ?? []))
    }

    func compilationDatabase(for projectURL: URL, context: any BuildSystemContext, onOutput: ((String) -> Void)?) async throws -> CompilationDatabaseOutput {
        let manager = context.xcodeBuildServerManager
        if manager.findExecutable() != nil, let xcode = XcodeBuildSystem.detect(in: projectURL), let url = try? await manager.configure(projectURL: projectURL, workspace: xcode.workspace, project: xcode.project, scheme: xcode.scheme, onOutput: onOutput) {
            return .buildServer(url)
        }
        return .native(projectURL.appendingPathComponent("Package.swift"))
    }
}
