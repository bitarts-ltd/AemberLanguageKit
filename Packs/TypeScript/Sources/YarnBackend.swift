/**
    @file YarnBackend.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Yarn's dependencies, Yarn 1 and Yarn 2+
    @details
    Reads the direct dependencies from package.json, as npm does, and
    the resolved graph from yarn.lock without running Yarn. Yarn 1's
    lockfile (its own format) keys each entry by the descriptors it
    satisfies ("chalk@^4.1.0"); a package's id is its name@version.
    Yarn 2 and later write YAML with a __metadata entry, descriptors
    with a protocol ("chalk@npm:^4.1.0") and each entry's resolution
    ("chalk@npm:4.1.2"), which is the package's id; the root
    workspace's entry gives the descriptors of the direct dependencies.
    A package's files are node_modules/<name> when installed there (Yarn
    1, or Yarn 2+ with the node-modules linker); Plug'n'Play keeps them
    in zip archives, so they show none.

    A workspace's members (package.json's "workspaces") are the
    graph's members, their dependencies looked up by their own ranges;
    Yarn 2+'s lockfile has an entry per workspace, which is a member's
    package and gives its dependencies' descriptors. A member's add,
    remove and rule change run as `yarn workspace <name> ...`, which
    needs the member's package.json to name it.

    Changes differ between the two: Yarn 1 updates with `yarn upgrade`,
    Yarn 2+ with `yarn up -R` (which keeps the rules; plain `yarn up`
    rewrites them to the newest). Adding takes --dev, --optional and
    --exact; Yarn 1 takes a folder as file:<path>.
*/

import Foundation
import AemberLanguageKit

/// @brief Yarn, for a package.json with yarn.lock
final class YarnBackend: PackageBackend {

    static let identifier = "yarn"
    static let displayName = "Yarn"
    static let toolName = "yarn"
    static var installHint: String {
        PackStrings.text("Install Yarn, with “corepack enable yarn” or from yarnpkg.com.").localized
    }

    static func manifest(in folder: URL) -> URL? {
        NodePackageManager.manifest(in: folder, for: .yarn)
    }

    let manifestURL: URL
    let runner: PackageToolRunner

    init(manifestURL: URL, runner: PackageToolRunner) {
        self.manifestURL = manifestURL
        self.runner = runner
    }

    var lockfileURLs: [URL] {
        [folder.appendingPathComponent("yarn.lock")]
    }

    func checkTool() -> PackageToolStatus {
        runner.find(Self.toolName).map { .available($0) } ?? .missing
    }

    func readGraph() throws -> PackageGraph {
        guard let manifest = try PackageJSON.object(at: manifestURL) else {
            throw PackageError.unreadable(manifestURL.lastPathComponent)
        }
        let text = try? String(contentsOf: lockfileURLs[0], encoding: .utf8)
        return Self.graph(manifest: manifest, lockText: text, folder: folder)
    }

    func declarationLine(of dependency: PackageDependency, in manifest: String) -> Int? {
        NPMBackend.declarationLine(of: dependency, in: manifest)
    }

    // MARK: - Which Yarn

    /// @brief Whether a lockfile is Yarn 2+'s.
    /// @param text The lockfile
    /// @return true when it has Yarn 2+'s __metadata entry
    static func isModernLockfile(_ text: String) -> Bool {
        text.contains("\n__metadata:") || text.hasPrefix("__metadata:")
    }

    /// @brief Whether a folder uses Yarn 2 or later.
    /// @detail
    /// By its lockfile; without one, by package.json's packageManager
    /// field (yarn@1 is Yarn 1), else by a .yarnrc.yml, which only Yarn
    /// 2+ reads.
    /// @param folder The folder
    /// @return true for Yarn 2+
    static func isModern(folder: URL) -> Bool {
        if let text = try? String(contentsOf: folder.appendingPathComponent("yarn.lock"), encoding: .utf8) {
            return isModernLockfile(text)
        }
        if let object = try? PackageJSON.object(at: folder.appendingPathComponent("package.json")),
           let field = object["packageManager"] as? String, field.hasPrefix("yarn@") {
            return !field.hasPrefix("yarn@1.")
        }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(".yarnrc.yml").path)
    }

    // MARK: - Changes

    func command(for change: PackageChange, graph: PackageGraph, manifest: String, member: PackageMember?) throws -> PackageCommand {
        try Self.command(for: change, graph: graph, modern: Self.isModern(folder: folder), member: member)
    }

    /// @brief The command for a change, for Yarn 1 or Yarn 2+.
    /// @param change The change
    /// @param graph The graph last read
    /// @param modern Whether the project uses Yarn 2+
    /// @param member The workspace member changed, or nil for the root
    /// @return The command
    /// @throws PackageError.unsupported for what Yarn can't do
    static func command(for change: PackageChange, graph: PackageGraph, modern: Bool, member: PackageMember? = nil) throws -> PackageCommand {
        var workspace: [String] = []
        switch change {
        case .add, .remove, .changeRule:
            if let member {
                guard member.hasName else { throw PackageCommand.unsupported(change, by: displayName) }
                workspace = ["workspace", try PackageCommand.checked(member.name)]
            }
        case .update, .resolve:
            break
        }
        func step(_ arguments: [String]) -> BuildStep {
            BuildStep(executable: toolName, arguments: workspace + arguments)
        }
        let path: (String) -> String = { modern ? $0 : "file:" + $0 }
        switch change {
        case .add(let spec, let kind):
            let arguments = try NodePackageCommands.addArguments(name: spec.name, rule: spec.rule, kind: kind, flags: NodePackageCommands.yarnFlags, path: path, change: change, tool: displayName)
            return PackageCommand(steps: [step(["add"] + arguments)])

        case .remove(let name, _):
            return PackageCommand(steps: [step(["remove", try PackageCommand.checked(name)])])

        case .update(let names):
            let checked = try names.map(PackageCommand.checked)
            guard modern else {
                return PackageCommand(steps: [step(["upgrade"] + checked)])
            }
            return PackageCommand(steps: [step(["up", "-R"] + (checked.isEmpty ? ["*"] : checked))])

        case .changeRule(let name, let kind, let rule):
            let dependency = member.map { $0.dependency(named: name, kind: kind) } ?? graph.dependency(named: name, kind: kind)
            guard let dependency, !dependency.isPath, rule.requirementString(exactPrefix: "") != nil else {
                throw PackageCommand.unsupported(change, by: displayName)
            }
            let arguments = try NodePackageCommands.addArguments(name: name, rule: rule, kind: kind, flags: NodePackageCommands.yarnFlags, path: path, change: change, tool: displayName)
            return PackageCommand(steps: [step(["add"] + arguments)])

        case .resolve:
            return PackageCommand(steps: [step(["install"])])
        }
    }

    // MARK: - yarn.lock

    /// @brief The package a descriptor names.
    /// @param descriptor "@types/node@npm:^20.0.0"
    /// @return "@types/node"
    static func name(ofDescriptor descriptor: String) -> String {
        guard let at = descriptor.dropFirst().firstIndex(of: "@") else { return descriptor }
        return String(descriptor[..<at])
    }

    /// @brief Puts package.json and yarn.lock together.
    /// @param manifest package.json's object
    /// @param lockText yarn.lock's text, nil without the file
    /// @param folder The project's folder, for checkouts
    /// @return The graph
    static func graph(manifest: [String: Any], lockText: String?, folder: URL) -> PackageGraph {
        let rootName = manifest["name"] as? String ?? folder.lastPathComponent
        let direct = NPMBackend.dependencies(of: manifest)
        let memberReads = PackageWorkspaces.folders(matching: PackageWorkspaces.patterns(in: manifest), in: folder).compactMap { path in
            PackageWorkspaces.readMember(path, in: folder).map { (path: path, read: $0) }
        }
        // A dependency on a sibling member is that member's package
        func memberPackage(named name: String, in lockGraph: LockGraph?) -> String? {
            memberReads.first { $0.read.name == name }.flatMap { lockGraph?.memberPackageIDs[$0.path] }
        }
        func members(_ lockGraph: LockGraph?) -> [PackageMember] {
            memberReads.map { path, read in
                PackageMember(
                    name: read.name,
                    path: path,
                    manifestURL: read.url,
                    dependencies: NPMBackend.dependencies(of: read.manifest).map { dependency in
                        var result = dependency
                        result.resolvedID = lockGraph?.memberIDs[path]?[dependency.name] ?? memberPackage(named: dependency.name, in: lockGraph)
                        return result
                    },
                    packageID: lockGraph?.memberPackageIDs[path],
                    hasName: read.hasName
                )
            }
        }
        guard let lockText else {
            var graph = PackageGraph(rootName: rootName, dependencies: direct, isResolved: false, hasEdges: false)
            graph.members = members(nil)
            return graph
        }
        let modern = isModernLockfile(lockText)
        let lock = LockfileText.parse(lockText, style: modern ? .yaml : .yarnClassic)
        let memberManifests = memberReads.map { (path: $0.path, manifest: $0.read.manifest) }
        var lockGraph = modern
            ? modernGraph(lock: lock, manifest: manifest, members: memberManifests)
            : classicGraph(lock: lock, manifest: manifest, members: memberManifests)
        // Yarn 1's lockfile leaves workspaces out: their package.json
        // makes them packages
        if !modern {
            for (path, read) in memberReads {
                let id = read.name + "@workspace:" + path
                lockGraph.packages.append(ResolvedPackage(id: id, name: read.name, version: read.manifest["version"] as? String, source: .path(path)))
                lockGraph.memberPackageIDs[path] = id
            }
        }
        let fileManager = FileManager.default
        for index in lockGraph.packages.indices {
            let package = lockGraph.packages[index]
            if case .path(let path) = package.source {
                let target = folder.appendingPathComponent(path).standardizedFileURL
                lockGraph.packages[index].checkout = fileManager.fileExists(atPath: target.path) ? target : nil
                continue
            }
            // Only the copy hoisted to the top, when it is this version
            let top = folder.appendingPathComponent("node_modules").appendingPathComponent(package.name)
            let installed = (try? PackageJSON.object(at: top.appendingPathComponent("package.json")))?["version"] as? String
            if installed != nil, installed == package.version {
                lockGraph.packages[index].checkout = top
            }
        }
        let dependencies = direct.map { dependency -> PackageDependency in
            var result = dependency
            result.resolvedID = lockGraph.directIDs[dependency.name] ?? memberPackage(named: dependency.name, in: lockGraph)
            return result
        }
        var graph = PackageGraph(rootName: rootName, dependencies: dependencies, packages: lockGraph.packages, isResolved: true, hasEdges: true)
        graph.members = members(lockGraph)
        return graph
    }

    /// What a lockfile gives, before checkouts and package.json
    struct LockGraph {

        /// The packages
        var packages: [ResolvedPackage]

        /// The id each direct dependency resolved to, by name
        var directIDs: [String: String]

        /// Each workspace member's dependencies' ids, by member path,
        /// then by name
        var memberIDs: [String: [String: String]] = [:]

        /// Each workspace member's own package id, by path
        var memberPackageIDs: [String: String] = [:]
    }

    /// @brief The requirement each direct dependency has in package.json,
    /// by name.
    /// @param manifest package.json's object
    /// @return The requirements as written
    static func requirements(in manifest: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for section in NPMBackend.sections {
            for (name, value) in manifest[section.key] as? [String: Any] ?? [:] where result[name] == nil {
                result[name] = value as? String ?? "*"
            }
        }
        return result
    }

    /// @brief Reads Yarn 1's lockfile.
    /// @detail
    /// Each entry is one package, name@version; its key lists the
    /// descriptors (name@range) it satisfies, which its dependents' and
    /// package.json's ranges look up.
    /// @param lock The lockfile, read
    /// @param manifest package.json's object
    /// @param members The workspace members' paths and package.json
    /// objects
    /// @return The packages and the direct ones' ids
    static func classicGraph(lock: [String: Any], manifest: [String: Any], members: [(path: String, manifest: [String: Any])] = []) -> LockGraph {
        var keyOfDescriptor: [String: String] = [:]
        var idOfKey: [String: String] = [:]
        var packages: [ResolvedPackage] = []
        var seen = Set<String>()
        for key in lock.keys.sorted() {
            guard let entry = lock[key] as? [String: Any], let first = LockfileText.descriptors(ofKey: key).first else { continue }
            for descriptor in LockfileText.descriptors(ofKey: key) {
                keyOfDescriptor[descriptor] = key
            }
            let name = name(ofDescriptor: first)
            let range = String(first.dropFirst(name.count + 1))
            let version = entry["version"] as? String
            let id = name + "@" + (version ?? range)
            idOfKey[key] = id
            guard seen.insert(id).inserted else { continue }
            var package = ResolvedPackage(id: id, name: name, version: version)
            let resolvedURL = entry["resolved"] as? String ?? ""
            if let path = NPMBackend.pathOfRequirement(range) {
                package.source = .path(path)
            } else if resolvedURL.hasPrefix("git") || resolvedURL.contains("codeload.github.com") || range.hasPrefix("github:") || range.hasPrefix("git") {
                let parts = resolvedURL.split(separator: "#", maxSplits: 1).map(String.init)
                package.source = .git(parts.first ?? resolvedURL)
                package.revision = parts.count > 1 ? parts[1] : nil
            } else {
                package.source = .registry(nil)
            }
            packages.append(package)
        }
        func lookup(_ descriptor: String) -> String? {
            keyOfDescriptor[descriptor].flatMap { idOfKey[$0] }
        }
        for key in lock.keys.sorted() {
            guard let entry = lock[key] as? [String: Any], let id = idOfKey[key], let index = packages.firstIndex(where: { $0.id == id }), packages[index].dependencies.isEmpty else { continue }
            var children: [String] = []
            for section in ["dependencies", "optionalDependencies"] {
                let entries = entry[section] as? [String: Any] ?? [:]
                children += entries.keys.sorted().compactMap { name in
                    (entries[name] as? String).flatMap { lookup(name + "@" + $0) }
                }
            }
            packages[index].dependencies = children
        }
        var directIDs: [String: String] = [:]
        for (name, requirement) in requirements(in: manifest) {
            directIDs[name] = lookup(name + "@" + requirement)
        }
        var graph = LockGraph(packages: packages, directIDs: directIDs)
        for member in members {
            var ids: [String: String] = [:]
            for (name, requirement) in requirements(in: member.manifest) {
                ids[name] = lookup(name + "@" + requirement)
            }
            graph.memberIDs[member.path] = ids
        }
        return graph
    }

    /// @brief Reads Yarn 2+'s lockfile.
    /// @detail
    /// Each entry but __metadata and the workspaces is one package,
    /// whose resolution is its id. Descriptors carry a protocol (npm:,
    /// file:, a link's ::locator=), so a range looks up as written, with
    /// npm: before it, or as the start of a descriptor followed by "::".
    /// The root workspace's dependencies give the direct ones'
    /// descriptors; without it, package.json's ranges are looked up.
    /// @param lock The lockfile, read
    /// @param manifest package.json's object
    /// @param members The workspace members' paths and package.json
    /// objects
    /// @return The packages and the direct ones' ids
    static func modernGraph(lock: [String: Any], manifest: [String: Any], members: [(path: String, manifest: [String: Any])] = []) -> LockGraph {
        var keyOfDescriptor: [String: String] = [:]
        var idOfKey: [String: String] = [:]
        var rootDependencies: [String: Any]?
        var workspaceDependencies: [String: [String: Any]] = [:]
        var workspaceIDs: [String: String] = [:]
        var packages: [ResolvedPackage] = []
        for key in lock.keys.sorted() where key != "__metadata" {
            guard let entry = lock[key] as? [String: Any] else { continue }
            let resolution = entry["resolution"] as? String ?? LockfileText.descriptors(ofKey: key).first ?? key
            for descriptor in LockfileText.descriptors(ofKey: key) {
                keyOfDescriptor[descriptor] = key
            }
            idOfKey[key] = resolution
            if let range = resolution.range(of: "@workspace:") {
                let path = String(resolution[range.upperBound...])
                if path == "." {
                    rootDependencies = entry["dependencies"] as? [String: Any] ?? [:]
                    continue
                }
                // Another workspace: a member, and a package others use
                workspaceDependencies[path] = entry["dependencies"] as? [String: Any] ?? [:]
                workspaceIDs[path] = resolution
                packages.append(ResolvedPackage(
                    id: resolution,
                    name: String(resolution[..<range.lowerBound]),
                    version: entry["version"] as? String,
                    source: .path(path)
                ))
                continue
            }
            let name = name(ofDescriptor: resolution)
            let reference = String(resolution.dropFirst(name.count + 1))
            var package = ResolvedPackage(id: resolution, name: name, version: entry["version"] as? String)
            if reference.hasPrefix("npm:") {
                package.source = .registry(nil)
            } else if let path = ["file:", "portal:", "link:"].first(where: reference.hasPrefix).map({ String(reference.dropFirst($0.count)) }) {
                package.source = .path(String(path.prefix { $0 != "#" && $0 != ":" }))
            } else if reference.contains("#commit=") || reference.hasPrefix("https://") || reference.hasPrefix("git") {
                let parts = reference.components(separatedBy: "#commit=")
                package.source = .git(parts[0].components(separatedBy: "#")[0])
                package.revision = parts.count > 1 ? parts[1] : nil
            } else {
                package.source = .unknown
            }
            packages.append(package)
        }
        func lookup(_ name: String, _ range: String) -> String? {
            for descriptor in [name + "@" + range, name + "@npm:" + range] {
                if let key = keyOfDescriptor[descriptor] {
                    return idOfKey[key]
                }
            }
            let prefix = name + "@" + range + "::"
            return keyOfDescriptor.first { $0.key.hasPrefix(prefix) }.flatMap { idOfKey[$0.value] }
        }
        for key in lock.keys.sorted() where key != "__metadata" {
            guard let entry = lock[key] as? [String: Any], let id = idOfKey[key], let index = packages.firstIndex(where: { $0.id == id }), packages[index].dependencies.isEmpty else { continue }
            let entries = entry["dependencies"] as? [String: Any] ?? [:]
            packages[index].dependencies = entries.keys.sorted().compactMap { name in
                (entries[name] as? String).flatMap { lookup(name, $0) }
            }
        }
        var directIDs: [String: String] = [:]
        for (name, requirement) in requirements(in: manifest) {
            let range = (rootDependencies?[name] as? String) ?? requirement
            directIDs[name] = lookup(name, range)
        }
        var graph = LockGraph(packages: packages, directIDs: directIDs)
        for member in members {
            var ids: [String: String] = [:]
            for (name, requirement) in requirements(in: member.manifest) {
                let range = (workspaceDependencies[member.path]?[name] as? String) ?? requirement
                ids[name] = lookup(name, range)
            }
            graph.memberIDs[member.path] = ids
            graph.memberPackageIDs[member.path] = workspaceIDs[member.path]
        }
        return graph
    }
}

extension PackageDependency {

    /// Whether the dependency is a folder, which has no rule to change
    var isPath: Bool {
        if case .path = rule {
            return true
        }
        return false
    }
}
