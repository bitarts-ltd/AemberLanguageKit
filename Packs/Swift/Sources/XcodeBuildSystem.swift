/**
    @file XcodeBuildSystem.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Xcode projects and workspaces as a build system.
    @details
    A project with an .xcworkspace or .xcodeproj in its root; with
    several of a kind, XcodeProjectLookup's (the one named like the
    folder, else the first by name). Users take the workspace over the
    project. It builds and tests with xcodebuild, writing a result
    bundle; the scheme is build.json's, else the one named like the
    project, else the first `xcodebuild -list -json` gives.

    For the language servers it configures xcode-build-server when
    that is installed, else writes compile_commands.json with
    XcodeGenerator.
*/

import Foundation
import AemberLanguageKit

/// @brief An Xcode workspace or project
struct XcodeBuildSystem: DetectableBuildSystem {

    static let identifier = "xcode"

    /// The workspace bundle's name, relative to the root
    var workspace: String?
    /// The project bundle's name, relative to the root
    var project: String?
    /// The scheme, when known; looked up later otherwise
    var scheme: String?

    var displayName: String {
        PackStrings.text("Xcode").localized
    }

    /// @brief The files inside the bundles that change when they are
    /// edited (a bundle's own date doesn't), the project's first since
    /// build settings live there
    var buildFiles: [String] {
        [project.map { "\($0)/project.pbxproj" }, workspace.map { "\($0)/contents.xcworkspacedata" }].compactMap { $0 }
    }

    static func detect(in projectRoot: URL) -> XcodeBuildSystem? {
        let (workspace, project) = XcodeProjectLookup.bundles(in: projectRoot)
        guard workspace != nil || project != nil else {
            return nil
        }
        return XcodeBuildSystem(workspace: workspace, project: project, scheme: nil)
    }

    func command(for action: BuildAction, in projectRoot: URL, config: BuildProjectConfig?, filter: String?, outputDirectory: URL, context: any BuildSystemContext) throws -> BuildCommand {
        var arguments: [String] = []
        if let workspace {
            arguments += ["-workspace", workspace]
        } else if let project {
            arguments += ["-project", project]
        }
        let container = (workspace ?? project).map { ($0 as NSString).deletingPathExtension }
        guard let scheme = config?.scheme ?? scheme ?? XcodeProjectLookup.preferredScheme(Self.schemes(in: projectRoot, system: self, context: context), named: container) else {
            throw BuildCommandError.noCommand(PackStrings.text("xcodebuild lists no scheme for this project; add \"scheme\" to .aember/build.json.").localized)
        }
        arguments += ["-scheme", scheme]
        if let configuration = config?.configuration {
            arguments += ["-configuration", configuration]
        }
        if let destination = config?.destination {
            arguments += ["-destination", destination]
        }
        let bundle = outputDirectory.appendingPathComponent("Result.xcresult")
        arguments += [action.rawValue, "-resultBundlePath", bundle.path]
        if let filter {
            arguments.append("-only-testing:" + filter)
        }
        var command = single("xcodebuild", arguments)
        command.report = BuildReportFile(bundle, format: XcodeResultBundleReader.format)
        return command
    }

    func compilationDatabase(for projectURL: URL, context: any BuildSystemContext, onOutput: ((String) -> Void)?) async throws -> CompilationDatabaseOutput {
        let manager = context.xcodeBuildServerManager
        //
        // xcode-build-server writes a buildServer.json that sourcekit-lsp
        // reads through the Build Server Protocol, which needs no
        // compilation database. Without it, xcodebuild's log gives one.
        //
        if manager.findExecutable() != nil {
            do {
                return .buildServer(try await manager.configure(projectURL: projectURL, workspace: workspace, project: project, scheme: scheme, onOutput: onOutput))
            } catch {
                onOutput?(String(format: PackStrings.text("xcode-build-server failed: %@. Falling back to xcodebuild.").localized, error.localizedDescription))
            }
        }
        return .generated(try await context.xcodeGenerator.generate(projectURL: projectURL, workspace: workspace, project: project, scheme: scheme, onOutput: onOutput))
    }

    /// @brief Lists an Xcode project's schemes: the context's, when it
    /// lists them itself (tests), else XcodeProjectLookup's with the
    /// context's xcodebuild.
    /// @param root The project folder
    /// @param system The project's Xcode build system
    /// @param context Aember's tools
    /// @return The schemes, empty when listing fails
    static func schemes(in root: URL, system: XcodeBuildSystem, context: any BuildSystemContext) -> [String] {
        if let lister = context as? XcodeSchemeLister {
            return lister.schemes(in: root, system: system)
        }
        return XcodeProjectLookup(xcodebuildPath: context.xcodebuildPath).schemes(in: root, workspace: system.workspace, project: system.project)
    }
}

/// @brief A context that lists Xcode schemes itself, so tests needn't
/// run xcodebuild
protocol XcodeSchemeLister {

    /// @brief The project's schemes.
    /// @param root The project folder
    /// @param system The project's Xcode build system
    /// @return The schemes
    func schemes(in root: URL, system: XcodeBuildSystem) -> [String]
}

// MARK: - The Xcode Tools

extension BuildSystemContext {

    /// xcodebuild: the context's, else the system's
    var xcodebuildPath: String {
        toolPath("xcodebuild") ?? "/usr/bin/xcodebuild"
    }

    /// Runs xcode-build-server, the context's or the one on the PATH
    var xcodeBuildServerManager: XcodeBuildServerManager {
        XcodeBuildServerManager(executablePath: toolPath("xcode-build-server"), xcodebuildPath: xcodebuildPath)
    }

    /// Writes a compilation database from xcodebuild's log
    var xcodeGenerator: XcodeGenerator {
        XcodeGenerator(executablePath: toolPath("xcodebuild"))
    }
}
