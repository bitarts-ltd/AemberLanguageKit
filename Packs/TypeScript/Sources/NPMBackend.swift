/**
    @file NPMBackend.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief npm's dependencies
    @details
    Reads a package.json's dependencies without the network or npm
    itself: the direct ones from package.json (dependencies,
    devDependencies, optionalDependencies), the resolved graph from
    package-lock.json (lockfile versions 2 and 3, whose packages map is
    keyed by install path). A package's dependencies are found as Node
    finds them, in the nearest node_modules up from the package, and
    its files are its folder in node_modules when installed. Running
    `npm ls` instead would take seconds on a large project and reads
    only what is installed. The parsers are static so tests feed them
    saved files.

    Changes run `npm install`, `npm uninstall` and `npm update`; a rule
    change installs the package again with the new requirement, in the
    section it was in.

    A workspace's members (package.json's "workspaces") are the
    graph's members: each member's dependencies come from its own
    package.json and resolve from its folder's key in the lockfile
    ("packages/a") as Node finds them; a change to one runs with
    `--workspace <folder>`.

    A package.json belongs to one of npm, pnpm and Yarn
    (NodePackageManager.detect); this backend takes it when the others
    don't. package.json's reading and its declarations are shared with
    PNPMBackend and YarnBackend.
*/

import Foundation
import AemberLanguageKit

/// @brief npm, for a package.json
final class NPMBackend: PackageBackend {

    static let identifier = "npm"
    static let displayName = "npm"
    static let toolName = "npm"
    static var installHint: String {
        PackStrings.text("Install Node.js, from nodejs.org or Homebrew.").localized
    }

    static func manifest(in folder: URL) -> URL? {
        NodePackageManager.manifest(in: folder, for: .npm)
    }

    let manifestURL: URL
    let runner: PackageToolRunner

    init(manifestURL: URL, runner: PackageToolRunner) {
        self.manifestURL = manifestURL
        self.runner = runner
    }

    var lockfileURLs: [URL] {
        [folder.appendingPathComponent("package-lock.json")]
    }

    func checkTool() -> PackageToolStatus {
        runner.find(Self.toolName).map { .available($0) } ?? .missing
    }

    func readGraph() throws -> PackageGraph {
        guard let manifest = try PackageJSON.object(at: manifestURL) else {
            throw PackageError.unreadable(manifestURL.lastPathComponent)
        }
        let lock = try PackageJSON.object(at: lockfileURLs[0])
        return Self.graph(manifest: manifest, lock: lock, folder: folder)
    }

    func declarationLine(of dependency: PackageDependency, in manifest: String) -> Int? {
        Self.declarationLine(of: dependency, in: manifest)
    }

    // MARK: - Changes

    func command(for change: PackageChange, graph: PackageGraph, manifest: String, member: PackageMember?) throws -> PackageCommand {
        let command = try rootCommand(for: change, graph: graph, member: member)
        guard let member else { return command }
        switch change {
        case .add, .remove, .changeRule:
            let workspace = ["--workspace", try PackageCommand.checked(member.path)]
            return PackageCommand(steps: command.steps.map { BuildStep(executable: $0.executable, arguments: $0.arguments + workspace) })
        case .update, .resolve:
            return command
        }
    }

    /// @brief The command for a change, before a member's --workspace.
    private func rootCommand(for change: PackageChange, graph: PackageGraph, member: PackageMember?) throws -> PackageCommand {
        switch change {
        case .add(let spec, let kind):
            guard kind != .build else {
                throw PackageCommand.unsupported(change, by: Self.displayName)
            }
            let name = try PackageCommand.checked(spec.name)
            var arguments = ["install"]
            switch spec.rule {
            case nil:
                arguments.append(name)
            case .path(let path)?:
                arguments.append(try PackageCommand.checked(path))
            case .exact(let version)?:
                arguments += [name + "@" + (try PackageCommand.checked(version)), "--save-exact"]
            case let rule?:
                guard let requirement = rule.requirementString(exactPrefix: "") else {
                    throw PackageCommand.unsupported(change, by: Self.displayName)
                }
                arguments.append(name + "@" + (try PackageCommand.checked(requirement)))
            }
            return PackageCommand(steps: [step(arguments + Self.saveArguments(kind))])

        case .remove(let name, _):
            return PackageCommand(steps: [step(["uninstall", try PackageCommand.checked(name)])])

        case .update(let names):
            return PackageCommand(steps: [step(["update"] + (try names.map(PackageCommand.checked)))])

        case .changeRule(let name, let kind, let rule):
            guard let dependency = dependency(named: name, kind: kind, in: graph, member: member), canChangeRule(of: dependency),
                  let requirement = rule.requirementString(exactPrefix: "")
            else {
                throw PackageCommand.unsupported(change, by: Self.displayName)
            }
            var arguments = ["install", try PackageCommand.checked(name) + "@" + (try PackageCommand.checked(requirement))]
            if case .exact = rule {
                arguments.append("--save-exact")
            }
            return PackageCommand(steps: [step(arguments + Self.saveArguments(kind))])

        case .resolve:
            return PackageCommand(steps: [step(["install"])])
        }
    }

    /// @brief npm install's flag for the section a kind goes in.
    /// @param kind The dependency's kind
    /// @return --save-dev, --save-optional, or none for dependencies
    static func saveArguments(_ kind: DependencyKind) -> [String] {
        switch kind {
        case .dev:
            return ["--save-dev"]
        case .optional:
            return ["--save-optional"]
        case .normal, .build:
            return []
        }
    }

    // MARK: - package.json

    /// The sections of package.json holding dependencies, by kind
    static let sections: [(key: String, kind: DependencyKind)] = [
        ("dependencies", .normal),
        ("devDependencies", .dev),
        ("optionalDependencies", .optional),
    ]

    /// @brief The direct dependencies package.json declares.
    /// @detail
    /// By section, then by name: JSON objects have no order once read,
    /// and npm writes them sorted. A file:, link: or portal:
    /// requirement, or a relative path, is a path.
    /// @param manifest package.json's object
    /// @return The dependencies, not yet resolved
    static func dependencies(of manifest: [String: Any]) -> [PackageDependency] {
        var seen = Set<String>()
        var result: [PackageDependency] = []
        for section in sections {
            let entries = manifest[section.key] as? [String: Any] ?? [:]
            for name in entries.keys.sorted() where seen.insert(name).inserted {
                let requirement = entries[name] as? String ?? "*"
                let rule: VersionRule = pathOfRequirement(requirement).map { .path($0) } ?? .requirement(requirement)
                result.append(PackageDependency(
                    name: name,
                    rule: rule,
                    kind: section.kind,
                    location: nil,
                    resolvedID: nil
                ))
            }
        }
        return result
    }

    /// @brief The folder a requirement names, if it names one.
    /// @param requirement "file:../kit", "link:kit", "portal:kit",
    /// "./kit" or "../kit"
    /// @return The path, or nil for a version requirement
    static func pathOfRequirement(_ requirement: String) -> String? {
        for prefix in ["file:", "link:", "portal:"] where requirement.hasPrefix(prefix) {
            return String(requirement.dropFirst(prefix.count))
        }
        if requirement.hasPrefix("./") || requirement.hasPrefix("../") || requirement.hasPrefix("/") {
            return requirement
        }
        return nil
    }

    // MARK: - package-lock.json

    /// @brief The folder a lockfile key installs into, or the
    /// package's name from it.
    /// @param key "node_modules/a/node_modules/@scope/b"
    /// @return "@scope/b"
    static func name(ofKey key: String) -> String {
        let marker = "node_modules/"
        guard let range = key.range(of: marker, options: .backwards) else {
            return URL(fileURLWithPath: key).lastPathComponent
        }
        return String(key[range.upperBound...])
    }

    /// @brief Where Node finds a dependency from a package: its own
    /// node_modules, then each one above it, then the root's.
    /// @param name The dependency's name
    /// @param key The package's lockfile key ("" for the root)
    /// @param packages The lockfile's packages
    /// @return The dependency's key, or nil if not in the lockfile
    static func resolve(_ name: String, from key: String, in packages: [String: Any]) -> String? {
        var base = key
        while true {
            let candidate = base.isEmpty ? "node_modules/\(name)" : "\(base)/node_modules/\(name)"
            if packages[candidate] != nil {
                return candidate
            }
            if base.isEmpty {
                return nil
            }
            // Up one package: drop "/node_modules/<name>", or leave a
            // top-level package for the root
            if let range = base.range(of: "/node_modules/", options: .backwards) {
                base = String(base[..<range.lowerBound])
            } else {
                base = ""
            }
        }
    }

    /// @brief Puts package.json and package-lock.json together.
    /// @detail
    /// Each installed package (a key under node_modules) is a package;
    /// a link (a workspace or file: dependency) takes its version and
    /// dependencies from its target's entry. Without a lockfile, or
    /// with a version 1 lockfile, the direct dependencies show as not
    /// resolved.
    /// @param manifest package.json's object
    /// @param lock package-lock.json's object, nil without the file
    /// @param folder The project's folder, for checkouts
    /// @return The graph
    static func graph(manifest: [String: Any], lock: [String: Any]?, folder: URL) -> PackageGraph {
        let rootName = manifest["name"] as? String ?? folder.lastPathComponent
        let direct = dependencies(of: manifest)
        guard let packages = lock?["packages"] as? [String: Any] else {
            var graph = PackageGraph(
                rootName: rootName,
                dependencies: direct,
                isResolved: false,
                hasEdges: false
            )
            graph.members = members(of: manifest, folder: folder, packages: nil)
            return graph
        }
        let fileManager = FileManager.default
        var resolved: [ResolvedPackage] = []
        for key in packages.keys.sorted() where key.hasPrefix("node_modules/") || key.contains("/node_modules/") {
            guard var entry = packages[key] as? [String: Any] else { continue }
            var dependencyBase = key
            var source: PackageSource
            var checkout = folder.appendingPathComponent(key)
            if entry["link"] as? Bool == true, let target = entry["resolved"] as? String {
                source = .path(target)
                checkout = folder.appendingPathComponent(target)
                if let targetEntry = packages[target] as? [String: Any] {
                    entry = targetEntry
                    dependencyBase = target
                }
            } else if let url = entry["resolved"] as? String, url.hasPrefix("git") {
                source = .git(url)
            } else {
                source = .registry(nil)
            }
            var names: [String] = []
            for section in ["dependencies", "optionalDependencies", "peerDependencies"] {
                names += (entry[section] as? [String: Any] ?? [:]).keys.sorted()
            }
            var seen = Set<String>()
            let children = names.filter { seen.insert($0).inserted }
                .compactMap { resolve($0, from: dependencyBase, in: packages) }
            resolved.append(ResolvedPackage(
                id: key,
                name: name(ofKey: key),
                version: entry["version"] as? String,
                source: source,
                checkout: fileManager.fileExists(atPath: checkout.path) ? checkout : nil,
                dependencies: children
            ))
        }
        let dependencies = direct.map { dependency -> PackageDependency in
            var result = dependency
            result.resolvedID = resolve(dependency.name, from: "", in: packages)
            return result
        }
        var graph = PackageGraph(
            rootName: rootName,
            dependencies: dependencies,
            packages: resolved,
            isResolved: true,
            hasEdges: true
        )
        graph.members = members(of: manifest, folder: folder, packages: packages)
        return graph
    }

    /// @brief A workspace's members, their dependencies resolved from
    /// their folders.
    /// @param manifest The root's package.json
    /// @param folder The root's folder
    /// @param packages The lockfile's packages, nil without one
    /// @return The members, by path
    static func members(of manifest: [String: Any], folder: URL, packages: [String: Any]?) -> [PackageMember] {
        let paths = PackageWorkspaces.folders(matching: PackageWorkspaces.patterns(in: manifest), in: folder)
        return paths.compactMap { path in
            guard let read = PackageWorkspaces.readMember(path, in: folder) else { return nil }
            let dependencies = Self.dependencies(of: read.manifest).map { dependency -> PackageDependency in
                var result = dependency
                result.resolvedID = packages.flatMap { resolve(dependency.name, from: path, in: $0) }
                return result
            }
            let link = "node_modules/" + read.name
            return PackageMember(
                name: read.name,
                path: path,
                manifestURL: read.url,
                dependencies: dependencies,
                packageID: packages?[link] != nil ? link : nil,
                hasName: read.hasName
            )
        }
    }

    // MARK: - The Declaration

    /// @brief The line declaring a dependency in package.json.
    /// @detail
    /// The first line with its name as a key after the line opening
    /// its kind's section.
    /// @param dependency The dependency
    /// @param manifest package.json's text
    /// @return The 1-based line, or nil
    static func declarationLine(of dependency: PackageDependency, in manifest: String) -> Int? {
        guard let section = sections.first(where: { $0.kind == dependency.kind })?.key else {
            return nil
        }
        var inSection = false
        let sectionKey = "\"\(section)\""
        let nameKey = "\"\(dependency.name)\""
        for (index, rawLine) in manifest.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(sectionKey) {
                inSection = true
                continue
            }
            if inSection {
                if line.hasPrefix("}") {
                    inSection = false
                } else if line.hasPrefix(nameKey) {
                    return index + 1
                }
            }
        }
        return nil
    }
}
