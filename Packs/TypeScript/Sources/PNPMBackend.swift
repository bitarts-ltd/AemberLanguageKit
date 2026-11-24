/**
    @file PNPMBackend.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief pnpm's dependencies, and which tool a package.json belongs to
    @details
    NodePackageManager decides whether npm, pnpm or Yarn manages a
    package.json: its packageManager field ("pnpm@9.15.0") when it has
    one, else the lockfile beside it (pnpm-lock.yaml, yarn.lock), else
    npm. Only that backend finds the manifest, so a project shows one
    folder for it.

    PNPMBackend reads the direct dependencies from package.json, as npm
    does, and the resolved graph from pnpm-lock.yaml without running
    pnpm: lockfile version 9 (packages and snapshots, keys
    "name@version(peer@version)") and 6 (packages only, keys
    "/name@version"), the root importer's sections giving each direct
    dependency's version. A link: dependency is a folder. A package's
    files are its folder in node_modules/.pnpm when installed.

    A workspace's members (pnpm-workspace.yaml's "packages") are the
    graph's members: each one's importer in the lockfile (its folder's
    path) gives its dependencies' versions, as the root's does, and a
    link: to a sibling is that folder.

    Changes run `pnpm add` (--save-dev, --save-optional, --save-exact),
    `pnpm remove`, `pnpm update` and `pnpm install`; a member's add,
    remove and rule change run with `--filter ./<folder>`.
    NodePackageCommands builds the add arguments npm-like tools share.
*/

import Foundation
import AemberLanguageKit

// MARK: - Which Tool

/// @brief The package managers that read a package.json
enum NodePackageManager: String {

    case npm
    case pnpm
    case yarn

    /// @brief Which tool manages the package.json in a folder.
    /// @detail
    /// package.json's packageManager field ("yarn@4.5.3") wins; else
    /// pnpm-lock.yaml means pnpm, yarn.lock Yarn, and anything else
    /// npm.
    /// @param folder The folder
    /// @return The tool, or nil without a package.json
    static func detect(in folder: URL) -> NodePackageManager? {
        let manifest = folder.appendingPathComponent("package.json")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: manifest.path) else { return nil }
        if let object = try? PackageJSON.object(at: manifest), let field = object["packageManager"] as? String,
           let manager = fromField(field) {
            return manager
        }
        if fileManager.fileExists(atPath: folder.appendingPathComponent("pnpm-lock.yaml").path) {
            return .pnpm
        }
        if fileManager.fileExists(atPath: folder.appendingPathComponent("yarn.lock").path) {
            return .yarn
        }
        return .npm
    }

    /// @brief The tool a packageManager field names.
    /// @param field "pnpm@9.15.0+sha512.…"
    /// @return The tool, or nil for one Aember doesn't know (bun)
    static func fromField(_ field: String) -> NodePackageManager? {
        let name = field.split(separator: "@", maxSplits: 1).first.map(String.init) ?? field
        return NodePackageManager(rawValue: name.trimmingCharacters(in: .whitespaces))
    }

    /// @brief A folder's package.json, when this tool manages it.
    /// @param folder The folder
    /// @param manager The tool asking
    /// @return package.json, or nil
    static func manifest(in folder: URL, for manager: NodePackageManager) -> URL? {
        detect(in: folder) == manager ? folder.appendingPathComponent("package.json") : nil
    }

    /// The backends' identifiers, for what npm-like tools share in the
    /// navigator and the Add Package panel
    static let identifiers: Set<String> = [NPMBackend.identifier, PNPMBackend.identifier, YarnBackend.identifier]
}

// MARK: - Commands

/// @brief The add arguments npm, pnpm and Yarn share
enum NodePackageCommands {

    /// A tool's flags for the section and an exact version
    struct Flags {
        var dev: String
        var optional: String
        var exact: String
    }

    /// pnpm's flags (npm's are the same)
    static let saveFlags = Flags(dev: "--save-dev", optional: "--save-optional", exact: "--save-exact")

    /// Yarn's flags
    static let yarnFlags = Flags(dev: "--dev", optional: "--optional", exact: "--exact")

    /// @brief The arguments after the verb for adding a package, or
    /// installing it again with another rule.
    /// @param name The package's name
    /// @param rule Its rule, nil for the newest
    /// @param kind The section it goes in
    /// @param flags The tool's flags
    /// @param path What to pass for a folder (its path, or file:path)
    /// @param change The change, for the error
    /// @param tool The tool's name, for the error
    /// @return The arguments
    /// @throws PackageError.unsupported for a build dependency or a rule
    /// that isn't a requirement
    static func addArguments(
        name: String,
        rule: VersionRule?,
        kind: DependencyKind,
        flags: Flags,
        path: (String) -> String,
        change: PackageChange,
        tool: String
    ) throws -> [String] {
        guard kind != .build else {
            throw PackageCommand.unsupported(change, by: tool)
        }
        let name = try PackageCommand.checked(name)
        var arguments: [String]
        switch rule {
        case nil:
            arguments = [name]
        case .path(let folder)?:
            arguments = [try PackageCommand.checked(path(folder))]
        case .exact(let version)?:
            arguments = [name + "@" + (try PackageCommand.checked(version)), flags.exact]
        case let rule?:
            guard let requirement = rule.requirementString(exactPrefix: "") else {
                throw PackageCommand.unsupported(change, by: tool)
            }
            arguments = [name + "@" + (try PackageCommand.checked(requirement))]
        }
        switch kind {
        case .dev:
            arguments.append(flags.dev)
        case .optional:
            arguments.append(flags.optional)
        case .normal, .build:
            break
        }
        return arguments
    }
}

// MARK: - pnpm

/// @brief pnpm, for a package.json with pnpm-lock.yaml
final class PNPMBackend: PackageBackend {

    static let identifier = "pnpm"
    static let displayName = "pnpm"
    static let toolName = "pnpm"
    static var installHint: String {
        PackStrings.text("Install pnpm, with “corepack enable pnpm” or from pnpm.io.").localized
    }

    static func manifest(in folder: URL) -> URL? {
        NodePackageManager.manifest(in: folder, for: .pnpm)
    }

    let manifestURL: URL
    let runner: PackageToolRunner

    init(manifestURL: URL, runner: PackageToolRunner) {
        self.manifestURL = manifestURL
        self.runner = runner
    }

    var lockfileURLs: [URL] {
        [folder.appendingPathComponent("pnpm-lock.yaml")]
    }

    func checkTool() -> PackageToolStatus {
        runner.find(Self.toolName).map { .available($0) } ?? .missing
    }

    func readGraph() throws -> PackageGraph {
        guard let manifest = try PackageJSON.object(at: manifestURL) else {
            throw PackageError.unreadable(manifestURL.lastPathComponent)
        }
        let lock = (try? String(contentsOf: lockfileURLs[0], encoding: .utf8)).map { LockfileText.parse($0) }
        let workspace = (try? String(contentsOf: folder.appendingPathComponent("pnpm-workspace.yaml"), encoding: .utf8)).map(PackageWorkspaces.pnpmPatterns) ?? []
        return Self.graph(manifest: manifest, lock: lock, folder: folder, workspace: workspace)
    }

    func declarationLine(of dependency: PackageDependency, in manifest: String) -> Int? {
        NPMBackend.declarationLine(of: dependency, in: manifest)
    }

    // MARK: - Changes

    func command(for change: PackageChange, graph: PackageGraph, manifest: String, member: PackageMember?) throws -> PackageCommand {
        let command = try rootCommand(for: change, graph: graph, member: member)
        guard let member else { return command }
        switch change {
        case .add, .remove, .changeRule:
            let filter = ["--filter", "./" + (try PackageCommand.checked(member.path))]
            return PackageCommand(steps: command.steps.map { BuildStep(executable: $0.executable, arguments: filter + $0.arguments) })
        case .update, .resolve:
            return command
        }
    }

    /// @brief The command for a change, before a member's --filter.
    private func rootCommand(for change: PackageChange, graph: PackageGraph, member: PackageMember?) throws -> PackageCommand {
        switch change {
        case .add(let spec, let kind):
            let arguments = try NodePackageCommands.addArguments(name: spec.name, rule: spec.rule, kind: kind, flags: NodePackageCommands.saveFlags, path: { $0 }, change: change, tool: Self.displayName)
            return PackageCommand(steps: [step(["add"] + arguments)])

        case .remove(let name, _):
            return PackageCommand(steps: [step(["remove", try PackageCommand.checked(name)])])

        case .update(let names):
            return PackageCommand(steps: [step(["update"] + (try names.map(PackageCommand.checked)))])

        case .changeRule(let name, let kind, let rule):
            guard let dependency = dependency(named: name, kind: kind, in: graph, member: member), canChangeRule(of: dependency), rule.requirementString(exactPrefix: "") != nil else {
                throw PackageCommand.unsupported(change, by: Self.displayName)
            }
            let arguments = try NodePackageCommands.addArguments(name: name, rule: rule, kind: kind, flags: NodePackageCommands.saveFlags, path: { $0 }, change: change, tool: Self.displayName)
            return PackageCommand(steps: [step(["add"] + arguments)])

        case .resolve:
            return PackageCommand(steps: [step(["install"])])
        }
    }

    // MARK: - pnpm-lock.yaml

    /// @brief A package's key in the lockfile without its peers.
    /// @param key "react-dom@18.3.1(react@18.3.1)", or v6's
    /// "/react-dom@18.3.1(react@18.3.1)"
    /// @return "react-dom@18.3.1"
    static func basePath(of key: String) -> String {
        var base = key.hasPrefix("/") ? String(key.dropFirst()) : key
        if let paren = base.firstIndex(of: "(") {
            base = String(base[..<paren])
        }
        return base
    }

    /// @brief A package's name and version from its key.
    /// @param key "@types/node@20.19.43", "localkit@file:localkit"
    /// @return The name and version, split at the last @ that doesn't
    /// start a scope
    static func nameAndVersion(of key: String) -> (name: String, version: String)? {
        let base = basePath(of: key)
        guard let at = base.dropFirst().firstIndex(of: "@") else { return nil }
        return (String(base[..<at]), String(base[base.index(after: at)...]))
    }

    /// @brief The folder pnpm installs a package in under
    /// node_modules/.pnpm.
    /// @param key The package's key
    /// @return "react-dom@18.3.1_react@18.3.1"
    static func storeFolderName(of key: String) -> String {
        var name = key.hasPrefix("/") ? String(key.dropFirst()) : key
        name = name.replacingOccurrences(of: ")(", with: "_")
        name = name.replacingOccurrences(of: "(", with: "_").replacingOccurrences(of: ")", with: "")
        return name.replacingOccurrences(of: "/", with: "+").replacingOccurrences(of: ":", with: "+")
    }

    /// @brief Puts package.json and pnpm-lock.yaml together.
    /// @detail
    /// The root importer (importers["."] in version 9, the top level in
    /// 6) gives each direct dependency's version; a version with link:
    /// is a folder, shown as a package of its own. Every snapshot (a
    /// package with its peers) is a package, with its dependencies and
    /// optional dependencies; its name, version and source come from
    /// its key and its packages entry. A folder's version is its
    /// package.json's. Each workspace member's importer resolves its
    /// dependencies the same way.
    /// @param manifest package.json's object
    /// @param lock pnpm-lock.yaml read, nil without the file
    /// @param folder The project's folder, for checkouts
    /// @param workspace pnpm-workspace.yaml's member patterns
    /// @return The graph
    static func graph(manifest: [String: Any], lock: [String: Any]?, folder: URL, workspace: [String] = []) -> PackageGraph {
        let rootName = manifest["name"] as? String ?? folder.lastPathComponent
        let direct = NPMBackend.dependencies(of: manifest)
        let memberPaths = PackageWorkspaces.folders(matching: workspace, in: folder)
        let memberManifests = memberPaths.compactMap { path in PackageWorkspaces.readMember(path, in: folder).map { (path, $0) } }
        guard let lock, lock["lockfileVersion"] != nil else {
            var graph = PackageGraph(rootName: rootName, dependencies: direct, isResolved: false, hasEdges: false)
            graph.members = memberManifests.map { path, read in
                PackageMember(name: read.name, path: path, manifestURL: read.url, dependencies: NPMBackend.dependencies(of: read.manifest), hasName: read.hasName)
            }
            return graph
        }
        let major = Int((lock["lockfileVersion"] as? String ?? "").prefix { $0.isNumber }) ?? 0
        let packages = lock["packages"] as? [String: Any] ?? [:]
        let snapshots = major >= 9 ? lock["snapshots"] as? [String: Any] ?? [:] : packages
        let prefix = major >= 9 ? "" : "/"
        let importer = (lock["importers"] as? [String: Any])?["."] as? [String: Any] ?? lock
        let fileManager = FileManager.default

        // A dependency's key: name@version, or its version when that is
        // a key itself (v6's file:, an alias's name@version)
        func key(_ name: String, _ version: String) -> String? {
            for candidate in [prefix + name + "@" + version, version, "/" + version] where snapshots[candidate] != nil {
                return candidate
            }
            return nil
        }

        func folderVersion(_ path: String) -> String? {
            let object = try? PackageJSON.object(at: folder.appendingPathComponent(path).appendingPathComponent("package.json"))
            return object?["version"] as? String
        }

        var resolved: [ResolvedPackage] = []
        for snapshotKey in snapshots.keys.sorted() {
            let snapshot = snapshots[snapshotKey] as? [String: Any] ?? [:]
            let entry = packages[snapshotKey] as? [String: Any] ?? packages[prefix + basePath(of: snapshotKey)] as? [String: Any] ?? [:]
            let resolution = entry["resolution"] as? [String: Any] ?? [:]
            var name = entry["name"] as? String
            var version = entry["version"] as? String
            if let split = nameAndVersion(of: snapshotKey) {
                name = name ?? split.name
                version = version ?? split.version
            }
            guard let name else { continue }
            var source = PackageSource.registry(nil)
            if let directory = resolution["directory"] as? String {
                source = .path(directory)
                version = folderVersion(directory)
            } else if let repository = resolution["repo"] as? String {
                source = .git(repository)
                version = nil
            } else if let tarball = resolution["tarball"] as? String, tarball.hasPrefix("file:") {
                source = .path(String(tarball.dropFirst("file:".count)))
            }
            var children: [String] = []
            for section in ["dependencies", "optionalDependencies"] {
                let entries = snapshot[section] as? [String: Any] ?? [:]
                children += entries.keys.sorted().compactMap { child in
                    (entries[child] as? String).flatMap { key(child, $0) }
                }
            }
            let store = folder.appendingPathComponent("node_modules/.pnpm")
                .appendingPathComponent(storeFolderName(of: snapshotKey))
                .appendingPathComponent("node_modules")
                .appendingPathComponent(name)
            resolved.append(ResolvedPackage(
                id: snapshotKey,
                name: name,
                version: version,
                revision: (resolution["commit"] as? String),
                source: source,
                checkout: fileManager.fileExists(atPath: store.path) ? store : nil,
                dependencies: children
            ))
        }

        // An importer's direct dependencies, resolved; base is the
        // importer's folder, which its link: paths are relative to
        func resolve(_ direct: [PackageDependency], importer: [String: Any], base: String) -> [PackageDependency] {
            var versions: [String: String] = [:]
            for section in NPMBackend.sections {
                let entries = importer[section.key] as? [String: Any] ?? [:]
                for (name, value) in entries {
                    if let map = value as? [String: Any], let version = map["version"] as? String {
                        versions[name] = version
                    } else if let version = value as? String {
                        versions[name] = version
                    }
                }
            }
            return direct.map { dependency -> PackageDependency in
                var result = dependency
                guard let version = versions[dependency.name] else { return result }
                guard version.hasPrefix("link:") else {
                    result.resolvedID = key(dependency.name, version)
                    return result
                }
                let path = relativePath(String(version.dropFirst("link:".count)), from: base)
                let id = dependency.name + "@link:" + path
                if !resolved.contains(where: { $0.id == id }) {
                    let target = folder.appendingPathComponent(path)
                    resolved.append(ResolvedPackage(
                        id: id,
                        name: dependency.name,
                        version: folderVersion(path),
                        source: .path(path),
                        checkout: fileManager.fileExists(atPath: target.path) ? target : nil
                    ))
                }
                result.resolvedID = id
                return result
            }
        }
        let dependencies = resolve(direct, importer: importer, base: "")
        let importers = lock["importers"] as? [String: Any] ?? [:]
        let members = memberManifests.map { path, read in
            PackageMember(
                name: read.name,
                path: path,
                manifestURL: read.url,
                dependencies: resolve(NPMBackend.dependencies(of: read.manifest), importer: importers[path] as? [String: Any] ?? [:], base: path),
                hasName: read.hasName
            )
        }
        // A direct package not in the store is still linked at the top
        for dependency in dependencies {
            guard let id = dependency.resolvedID, let index = resolved.firstIndex(where: { $0.id == id }), resolved[index].checkout == nil else { continue }
            let top = folder.appendingPathComponent("node_modules").appendingPathComponent(dependency.name)
            if fileManager.fileExists(atPath: top.path) {
                resolved[index].checkout = top
            }
        }
        var graph = PackageGraph(rootName: rootName, dependencies: dependencies, packages: resolved, isResolved: true, hasEdges: true)
        // A member another one links to is that package
        graph.members = members.map { member in
            var result = member
            result.packageID = resolved.first { $0.source == .path(member.path) }?.id
            return result
        }
        return graph
    }

    /// @brief A link: path from an importer's folder, as relative to
    /// the root.
    /// @param path The path as written ("../shared")
    /// @param base The importer's folder ("" for the root)
    /// @return The path from the root ("packages/shared")
    static func relativePath(_ path: String, from base: String) -> String {
        guard !base.isEmpty else { return path }
        var parts = base.split(separator: "/").map(String.init)
        for component in path.split(separator: "/").map(String.init) {
            switch component {
            case ".":
                continue
            case "..":
                if !parts.isEmpty {
                    parts.removeLast()
                }
            default:
                parts.append(component)
            }
        }
        return parts.joined(separator: "/")
    }
}
