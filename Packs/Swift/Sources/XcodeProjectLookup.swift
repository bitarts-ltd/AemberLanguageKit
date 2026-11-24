/**
    @file XcodeProjectLookup.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Finds an Xcode project's workspace, project and scheme.
    @details
    One rule for the build system detector, the compilation database
    (XcodeGenerator), xcode-build-server and builds (⌘B and the MCP
    build tool), so they all pick the same bundle and scheme:

    - Bundles: a workspace is used over a project. With several of one
      kind in the project folder, the one named like the folder, else
      the first by name.
    - Schemes: listed with `xcodebuild -list -json`, run in the project
      folder with its xcode environment (`.aember/xcode-env`). The
      scheme named like the workspace or project, else the first
      listed.
*/

import Foundation
import AemberLanguageKit

/// @brief Finds an Xcode project's bundles and schemes.
struct XcodeProjectLookup {

    /// Path to the xcodebuild executable that lists schemes
    var xcodebuildPath: String

    /// @brief Create a lookup.
    /// @param xcodebuildPath Path to xcodebuild, replaceable in tests
    /// @return Nothing
    init(xcodebuildPath: String = "/usr/bin/xcodebuild") {
        self.xcodebuildPath = xcodebuildPath
    }

    // MARK: - Bundles

    /// @brief The workspace and project bundles in a folder.
    /// @param root The project folder
    /// @return The preferred workspace and the preferred project, each
    /// nil when the folder has none (both nil when it can't be read)
    static func bundles(in root: URL) -> (workspace: String?, project: String?) {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: root.path
        )) ?? []
        let folder = root.lastPathComponent
        return (
            preferredBundle(names, withExtension: "xcworkspace", folder: folder),
            preferredBundle(names, withExtension: "xcodeproj", folder: folder)
        )
    }

    /// @brief The one bundle to build in a folder.
    /// @param root The project folder
    /// @return The preferred workspace with project nil, else the
    /// preferred project with workspace nil; nil when there is neither
    static func container(in root: URL) -> (workspace: String?, project: String?)? {
        let found = bundles(in: root)
        if let workspace = found.workspace {
            return (workspace, nil)
        }
        if let project = found.project {
            return (nil, project)
        }
        return nil
    }

    /// @brief The bundle of one kind to use among a folder's entries.
    /// @param names The folder's entry names
    /// @param pathExtension "xcworkspace" or "xcodeproj"
    /// @param folder The folder's own name
    /// @return The one named like the folder, else the first by name;
    /// nil when there is none of the kind
    static func preferredBundle(
        _ names: [String],
        withExtension pathExtension: String,
        folder: String
    ) -> String? {
        let bundles = names
            .filter { ($0 as NSString).pathExtension == pathExtension }
            .sorted()
        return bundles.first {
            ($0 as NSString).deletingPathExtension == folder
        } ?? bundles.first
    }

    // MARK: - Schemes

    /// @brief The scheme to use for a workspace or project.
    /// @param root The project folder
    /// @param workspace The workspace's name, if building one
    /// @param project The project's name, used when workspace is nil
    /// @return The preferred scheme, nil when xcodebuild lists none
    func scheme(in root: URL, workspace: String?, project: String?) -> String? {
        let container = (workspace ?? project).map {
            ($0 as NSString).deletingPathExtension
        }
        return Self.preferredScheme(
            schemes(in: root, workspace: workspace, project: project),
            named: container
        )
    }

    /// @brief Lists a workspace's or project's schemes with
    /// `xcodebuild -list -json`.
    /// @detail
    /// Blocks while xcodebuild runs; call it off the main thread.
    /// @param root The project folder, where xcodebuild runs
    /// @param workspace The workspace's name, if listing one
    /// @param project The project's name, used when workspace is nil
    /// @return The schemes, empty when listing fails
    func schemes(in root: URL, workspace: String?, project: String?) -> [String] {
        var arguments = ["-list", "-json"]
        if let workspace {
            arguments += ["-workspace", workspace]
        } else if let project {
            arguments += ["-project", project]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcodebuildPath)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = BuildEnvironmentLoader.loadEnvironment(
            projectURL: root,
            identifier: "xcode"
        )
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            return []
        }
        let data = process.readToEndAndWait(output: output, error: error).output
        return Self.schemes(fromListJSON: data)
    }

    /// @brief The schemes in `xcodebuild -list -json` output.
    /// @param data The output
    /// @return The workspace's or project's schemes, empty when the
    /// output names none
    static func schemes(fromListJSON data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else {
            return []
        }
        let container = object["workspace"] as? [String: Any]
            ?? object["project"] as? [String: Any]
        return container?["schemes"] as? [String] ?? []
    }

    /// @brief The scheme to use among a project's schemes.
    /// @param schemes The project's schemes
    /// @param container The workspace's or project's name, without its
    /// extension
    /// @return The one named like the container, else the first
    static func preferredScheme(_ schemes: [String], named container: String?) -> String? {
        if let container, schemes.contains(container) {
            return container
        }
        return schemes.first
    }
}
