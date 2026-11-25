/**
    @file SwiftPMBackend.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Swift Package Manager's dependencies
    @details
    Reads a Package.swift's dependencies without the network: the
    direct ones from `swift package dump-package`, the pins from
    Package.resolved (versions 1 to 3), and, once the package has been
    resolved (.build/workspace-state.json exists), the edges and
    checkouts from `swift package show-dependencies --format json`,
    which would otherwise resolve and fetch. Before that, the pins show
    as a flat list without edges, and path dependencies as themselves.
    The parsers are static so tests feed them saved output.

    Changes run `swift package add-dependency` (then
    add-target-dependency per product), `update` and `resolve`. SwiftPM
    has no remove-dependency, so Remove edits Package.swift's text
    (SwiftPMManifestEditor) and resolves; a rule change removes only
    the declaration and adds it again with the new rule.
*/

import Foundation
import AemberLanguageKit

/// @brief Swift Package Manager, for a Package.swift
final class SwiftPMBackend: PackageBackend {

    static let identifier = "swiftpm"
    static let displayName = "Swift"
    static let toolName = "swift"
    static var installHint: String {
        PackStrings.text("Install Xcode, or the Swift toolchain from swift.org.").localized
    }

    static func manifest(in folder: URL) -> URL? {
        let url = folder.appendingPathComponent("Package.swift")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    let manifestURL: URL
    let runner: PackageToolRunner

    init(manifestURL: URL, runner: PackageToolRunner) {
        self.manifestURL = manifestURL
        self.runner = runner
    }

    var lockfileURLs: [URL] {
        [folder.appendingPathComponent("Package.resolved")]
    }

    func checkTool() -> PackageToolStatus {
        runner.find(Self.toolName).map { .available($0) } ?? .missing
    }

    func readGraph() throws -> PackageGraph {
        let dump = try Self.parseDump(
            runTool(runner, ["package", "dump-package"]),
            folder: folder
        )
        let resolvedURL = lockfileURLs[0]
        let pins = FileManager.default.fileExists(atPath: resolvedURL.path)
            ? try Self.parseResolved(Data(contentsOf: resolvedURL))
            : nil
        var tree: SwiftPMShowDependencies?
        let state = folder.appendingPathComponent(".build/workspace-state.json")
        if FileManager.default.fileExists(atPath: state.path) {
            tree = try? Self.parseShowDependencies(
                runTool(runner, ["package", "show-dependencies", "--format", "json"])
            )
        }
        return Self.graph(
            dump: dump,
            pins: pins,
            tree: tree,
            checkouts: folder.appendingPathComponent(".build/checkouts"),
            registries: SwiftRegistryConfiguration.load(for: folder)
        )
    }

    func declarationLine(of dependency: PackageDependency, in manifest: String) -> Int? {
        Self.declarationLine(of: dependency, in: manifest, folder: folder)
    }

    // MARK: - Changes

    /// SwiftPM has no workspaces, so member is always nil
    func command(for change: PackageChange, graph: PackageGraph, manifest: String, member: PackageMember?) throws -> PackageCommand {
        let resolve = step(["package", "resolve"])
        switch change {
        case .add(let spec, let kind):
            guard kind == .normal else {
                throw PackageCommand.unsupported(change, by: Self.displayName)
            }
            let type = Self.sourceType(of: spec)
            var steps = [step(try Self.addArguments(location: spec.name, rule: spec.rule, type: type, change: change))]
            let identity = type == "registry" ? spec.name.lowercased() : Self.identity(ofLocation: spec.name)
            for (product, target) in spec.products {
                steps.append(step([
                    "package", "add-target-dependency",
                    try PackageCommand.checked(product), try PackageCommand.checked(target),
                    "--package", identity,
                ]))
            }
            return PackageCommand(steps: steps + [resolve])

        case .remove(let name, _):
            let dependency = try Self.dependency(name, in: graph)
            guard let text = SwiftPMManifestEditor.removing(dependency, from: manifest, folder: folder, products: true) else {
                throw PackageError.notWrittenLiterally(name)
            }
            return PackageCommand(manifestText: text, steps: [resolve])

        case .update(let names):
            return PackageCommand(steps: [step(["package", "update"] + (try names.map(PackageCommand.checked)))])

        case .changeRule(let name, _, let rule):
            let dependency = try Self.dependency(name, in: graph)
            guard canChangeRule(of: dependency), let location = dependency.location else {
                throw PackageCommand.unsupported(change, by: Self.displayName)
            }
            guard let text = SwiftPMManifestEditor.removing(dependency, from: manifest, folder: folder, products: false) else {
                throw PackageError.notWrittenLiterally(name)
            }
            let type = location == dependency.name && !location.contains("/") ? "registry" : "url"
            let add = try Self.addArguments(location: location, rule: rule, type: type, change: change)
            return PackageCommand(manifestText: text, steps: [step(add), resolve])

        case .resolve:
            return PackageCommand(steps: [resolve])
        }
    }

    /// @brief A direct dependency of the graph, by name.
    /// @param name Its name
    /// @param graph The graph
    /// @return The dependency
    /// @throws PackageError.unsupported if there is none
    private static func dependency(_ name: String, in graph: PackageGraph) throws -> PackageDependency {
        guard let dependency = graph.dependency(named: name) else {
            throw PackageError.unsupported(String(
                format: PackStrings.text("%@ isn’t a dependency of this package.").localized,
                name
            ))
        }
        return dependency
    }

    /// @brief What add-dependency's --type is for a package to add: a
    /// folder (a path rule, or a path that exists), a registry identity
    /// (scope.name, no slashes), else a URL.
    /// @param spec The package
    /// @return "path", "registry" or "url"
    static func sourceType(of spec: PackageSpec) -> String {
        if case .path = spec.rule {
            return "path"
        }
        let name = spec.name
        if name.contains("://") || name.hasPrefix("git@") {
            return "url"
        }
        if name.hasPrefix("/") || name.hasPrefix(".") || name.hasPrefix("~") {
            return "path"
        }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 2, !name.contains("/"), parts.allSatisfy({ !$0.isEmpty }) {
            return "registry"
        }
        return "url"
    }

    /// @brief add-dependency's arguments for a location and rule.
    /// @param location The URL, folder or registry identity
    /// @param rule The rule; a URL or registry package needs one
    /// @param type "url", "path" or "registry"
    /// @param change The change, for the error
    /// @return The arguments after `swift`
    /// @throws PackageError.unsupported for a rule SwiftPM doesn't
    /// take, or none where one is needed
    static func addArguments(
        location: String,
        rule: VersionRule?,
        type: String,
        change: PackageChange
    ) throws -> [String] {
        var arguments = ["package", "add-dependency", try PackageCommand.checked(location)]
        switch rule {
        case .upToNextMajor(let version)?:
            arguments += ["--from", try PackageCommand.checked(version)]
        case .upToNextMinor(let version)?:
            arguments += ["--up-to-next-minor-from", try PackageCommand.checked(version)]
        case .exact(let version)?:
            arguments += ["--exact", try PackageCommand.checked(version)]
        case .range(let lower, let upper)?:
            arguments += ["--from", try PackageCommand.checked(lower), "--to", try PackageCommand.checked(upper)]
        case .branch(let branch)?:
            arguments += ["--branch", try PackageCommand.checked(branch)]
        case .revision(let revision)?:
            arguments += ["--revision", try PackageCommand.checked(revision)]
        case .path?:
            guard type == "path" else { throw PackageCommand.unsupported(change, by: displayName) }
        case .requirement?:
            throw PackageCommand.unsupported(change, by: displayName)
        case nil:
            guard type == "path" else {
                throw PackageError.unsupported(PackStrings.text("Choose a version rule for the package.").localized)
            }
        }
        if type != "url" {
            arguments += ["--type", type]
        }
        return arguments
    }

    // MARK: - dump-package

    /// @brief What dump-package says of a manifest
    struct Dump: Equatable {

        /// The package's name
        var name: String

        /// Its dependencies, in manifest order, not yet resolved
        var dependencies: [PackageDependency]

        /// Its targets a product can be added to (regular, executable,
        /// test and macro targets), in manifest order
        var targets: [String] = []
    }

    /// The target types add-target-dependency can add a product to
    static let dependentTargetTypes: Set<String> = ["regular", "executable", "test", "macro"]

    /// @brief Reads dump-package's JSON.
    /// @detail
    /// Each dependency is an object with one key, sourceControl,
    /// fileSystem or registry, holding a one-element array. A path is
    /// shown relative to the manifest's folder.
    /// @param data The JSON
    /// @param folder The manifest's folder
    /// @return The name and dependencies
    /// @throws PackageError.unreadable if it isn't dump-package's
    static func parseDump(_ data: Data, folder: URL) throws -> Dump {
        let object = try PackageJSON.object(data, name: "dump-package")
        guard let name = object["name"] as? String else {
            throw PackageError.unreadable("dump-package")
        }
        let entries = object["dependencies"] as? [[String: Any]] ?? []
        let dependencies = entries.compactMap { entry -> PackageDependency? in
            if let source = (entry["sourceControl"] as? [[String: Any]])?.first,
               let identity = source["identity"] as? String {
                let location = source["location"] as? [String: Any]
                let remote = (location?["remote"] as? [[String: Any]])?.first?["urlString"] as? String
                let local = (location?["local"] as? [String])?.first
                return PackageDependency(
                    name: identity,
                    rule: rule(source["requirement"]),
                    location: remote ?? local,
                    resolvedID: nil
                )
            }
            if let source = (entry["fileSystem"] as? [[String: Any]])?.first,
               let identity = source["identity"] as? String,
               let path = source["path"] as? String {
                let display = URL(fileURLWithPath: path).packageDisplayPath(relativeTo: folder)
                return PackageDependency(
                    name: identity,
                    rule: .path(display),
                    location: path,
                    resolvedID: nil
                )
            }
            if let source = (entry["registry"] as? [[String: Any]])?.first,
               let identity = source["identity"] as? String {
                return PackageDependency(
                    name: identity,
                    rule: rule(source["requirement"]),
                    location: identity,
                    resolvedID: nil
                )
            }
            return nil
        }
        let targets = (object["targets"] as? [[String: Any]] ?? []).compactMap { target -> String? in
            guard let name = target["name"] as? String,
                  dependentTargetTypes.contains(target["type"] as? String ?? "regular")
            else {
                return nil
            }
            return name
        }
        return Dump(name: name, dependencies: dependencies, targets: targets)
    }

    /// @brief A dump-package requirement as a rule.
    /// @detail
    /// A range up to the next major is from:, up to the next minor is
    /// upToNextMinor, anything else a range.
    /// @param value The requirement object
    /// @return The rule, or nil if it isn't one dump-package writes
    static func rule(_ value: Any?) -> VersionRule? {
        guard let requirement = value as? [String: Any] else { return nil }
        if let range = (requirement["range"] as? [[String: Any]])?.first,
           let lower = range["lowerBound"] as? String,
           let upper = range["upperBound"] as? String {
            if upper == nextVersion(after: lower, major: true) {
                return .upToNextMajor(lower)
            }
            if upper == nextVersion(after: lower, major: false) {
                return .upToNextMinor(lower)
            }
            return .range(lower, upper)
        }
        if let exact = (requirement["exact"] as? [String])?.first {
            return .exact(exact)
        }
        if let branch = (requirement["branch"] as? [String])?.first {
            return .branch(branch)
        }
        if let revision = (requirement["revision"] as? [String])?.first {
            return .revision(revision)
        }
        return nil
    }

    /// @brief The next major or minor version, as SwiftPM writes the
    /// upper bound of from: and upToNextMinor.
    /// @param version A semantic version (1.2.3)
    /// @param major Whether the next major, else the next minor
    /// @return The version (2.0.0, 1.3.0), or nil if not semantic
    static func nextVersion(after version: String, major: Bool) -> String? {
        let parts = version.split(separator: ".").prefix(2).compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return major ? "\(parts[0] + 1).0.0" : "\(parts[0]).\(parts[1] + 1).0"
    }

    // MARK: - Package.resolved

    /// @brief One pin in Package.resolved
    struct Pin: Equatable {
        var identity: String
        var kind: String
        var location: String
        var version: String?
        var revision: String?
        var branch: String?
    }

    /// @brief Reads Package.resolved, versions 1 to 3.
    /// @detail
    /// Version 1 keeps its pins under object, by package name and
    /// repositoryURL; its identity is the URL's last component, lower
    /// cased, as SwiftPM derives it.
    /// @param data The file
    /// @return The pins
    /// @throws PackageError.unreadable if it isn't Package.resolved
    static func parseResolved(_ data: Data) throws -> [Pin] {
        let object = try PackageJSON.object(data, name: "Package.resolved")
        if let pins = object["pins"] as? [[String: Any]] {
            return pins.compactMap { pin in
                guard let identity = pin["identity"] as? String else { return nil }
                let state = pin["state"] as? [String: Any] ?? [:]
                return Pin(
                    identity: identity,
                    kind: pin["kind"] as? String ?? "remoteSourceControl",
                    location: pin["location"] as? String ?? "",
                    version: state["version"] as? String,
                    revision: state["revision"] as? String,
                    branch: state["branch"] as? String
                )
            }
        }
        if let pins = (object["object"] as? [String: Any])?["pins"] as? [[String: Any]] {
            return pins.compactMap { pin in
                guard let location = pin["repositoryURL"] as? String else { return nil }
                let state = pin["state"] as? [String: Any] ?? [:]
                return Pin(
                    identity: identity(ofLocation: location),
                    kind: "remoteSourceControl",
                    location: location,
                    version: state["version"] as? String,
                    revision: state["revision"] as? String,
                    branch: state["branch"] as? String
                )
            }
        }
        throw PackageError.unreadable("Package.resolved")
    }

    // MARK: - show-dependencies

    /// @brief One package in show-dependencies' tree
    struct SwiftPMShowDependencies: Equatable {
        var identity: String
        var name: String
        var url: String
        var version: String
        var path: String
        var dependencies: [SwiftPMShowDependencies]
    }

    /// @brief Reads show-dependencies' JSON tree.
    /// @param data The JSON
    /// @return The root package, with its dependencies under it
    /// @throws PackageError.unreadable if it isn't the tree
    static func parseShowDependencies(_ data: Data) throws -> SwiftPMShowDependencies {
        let object = try PackageJSON.object(data, name: "show-dependencies")
        guard let node = showNode(object) else {
            throw PackageError.unreadable("show-dependencies")
        }
        return node
    }

    /// @brief One node of show-dependencies' tree, with its children.
    /// @param object The node's object
    /// @return The node, or nil without an identity
    private static func showNode(_ object: [String: Any]) -> SwiftPMShowDependencies? {
        guard let identity = object["identity"] as? String else { return nil }
        let children = object["dependencies"] as? [[String: Any]] ?? []
        return SwiftPMShowDependencies(
            identity: identity,
            name: object["name"] as? String ?? identity,
            url: object["url"] as? String ?? "",
            version: object["version"] as? String ?? "unspecified",
            path: object["path"] as? String ?? "",
            dependencies: children.compactMap(showNode)
        )
    }

    // MARK: - The Graph

    /// @brief Puts dump-package, the pins and the tree together.
    /// @detail
    /// Every pin is a package. With the tree, its nodes add the edges,
    /// the checkouts, and the path dependencies, which aren't pinned;
    /// without it, path dependencies are packages without edges, and a
    /// pin's checkout is its folder in .build/checkouts if there.
    /// @param dump The manifest's dependencies
    /// @param pins Package.resolved's pins, nil without the file
    /// @param tree show-dependencies' tree, nil if not run
    /// @param checkouts The .build/checkouts folder
    /// @param registries The package registries, for registry pins'
    /// sources
    /// @return The graph
    static func graph(
        dump: Dump,
        pins: [Pin]?,
        tree: SwiftPMShowDependencies?,
        checkouts: URL,
        registries: SwiftRegistryConfiguration = SwiftRegistryConfiguration()
    ) -> PackageGraph {
        var packages: [String: ResolvedPackage] = [:]
        var order: [String] = []
        func add(_ package: ResolvedPackage) {
            if packages[package.id] == nil {
                order.append(package.id)
            }
            packages[package.id] = package
        }

        let fileManager = FileManager.default
        for pin in pins ?? [] {
            let source: PackageSource
            switch pin.kind {
            case "registry":
                source = .registry(registries.registry(for: pin.identity)?.absoluteString)
            case "localSourceControl":
                source = .path(pin.location)
            default:
                source = .git(pin.location)
            }
            let folderName = identity(ofLocation: pin.location)
            let checkout = [pin.identity, folderName, URL(fileURLWithPath: pin.location).deletingPathExtension().lastPathComponent]
                .map { checkouts.appendingPathComponent($0) }
                .first { fileManager.fileExists(atPath: $0.path) }
            add(ResolvedPackage(
                id: pin.identity,
                name: pin.identity,
                version: pin.version,
                revision: pin.revision,
                branch: pin.branch,
                source: source,
                checkout: checkout
            ))
        }

        // Path dependencies resolve to themselves
        for dependency in dump.dependencies {
            guard case .path = dependency.rule, let path = dependency.location,
                  packages[dependency.name] == nil else {
                continue
            }
            add(ResolvedPackage(
                id: dependency.name,
                name: dependency.name,
                source: .path(path),
                checkout: URL(fileURLWithPath: path)
            ))
        }

        if let tree {
            func visit(_ node: SwiftPMShowDependencies) {
                let children = node.dependencies.map(\.identity)
                var package = packages[node.identity] ?? ResolvedPackage(
                    id: node.identity,
                    name: node.identity,
                    version: node.version == "unspecified" ? nil : node.version,
                    source: node.url.hasPrefix("/") ? .path(node.url) : .git(node.url)
                )
                package.dependencies = children
                if !node.path.isEmpty {
                    package.checkout = URL(fileURLWithPath: node.path)
                }
                add(package)
                node.dependencies.forEach(visit)
            }
            tree.dependencies.forEach(visit)
        }

        // Identities are case-insensitive: a registry identity keeps the
        // manifest's case in dump-package, and is lower cased in its pin
        let dependencies = dump.dependencies.map { dependency -> PackageDependency in
            var resolved = dependency
            resolved.resolvedID = [dependency.name, dependency.name.lowercased()]
                .first { packages[$0] != nil }
            return resolved
        }
        // Only path dependencies need no Package.resolved
        let onlyPaths = dump.dependencies.allSatisfy {
            if case .path = $0.rule {
                return true
            }
            return false
        }
        var graph = PackageGraph(
            rootName: dump.name,
            dependencies: dependencies,
            packages: order.compactMap { packages[$0] },
            isResolved: pins != nil || tree != nil || onlyPaths,
            hasEdges: tree != nil
        )
        graph.targets = dump.targets
        return graph
    }

    // MARK: - The Declaration

    /// @brief The line of a dependency's .package(...) in Package.swift.
    /// @detail
    /// The first line, outside a line comment, with a string literal
    /// naming it: its URL as written, its registry identity, or a path
    /// that is the dependency's folder.
    /// @param dependency The dependency
    /// @param manifest Package.swift's text
    /// @param folder The manifest's folder, for relative paths
    /// @return The 1-based line, or nil
    static func declarationLine(
        of dependency: PackageDependency,
        in manifest: String,
        folder: URL
    ) -> Int? {
        guard let location = dependency.location else { return nil }
        let isPath: Bool
        if case .path = dependency.rule {
            isPath = true
        } else {
            isPath = false
        }
        let target = URL(fileURLWithPath: location).standardizedFileURL.resolvingSymlinksInPath().path
        let lines = manifest.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            for literal in stringLiterals(in: line) {
                if isPath {
                    let url = literal.hasPrefix("/")
                        ? URL(fileURLWithPath: literal)
                        : folder.appendingPathComponent(literal)
                    if url.standardizedFileURL.resolvingSymlinksInPath().path == target {
                        return index + 1
                    }
                } else if literal == location {
                    return index + 1
                }
            }
        }
        return nil
    }

    /// @brief The contents of the double-quoted string literals in a
    /// line of Swift, without escapes, up to a line comment.
    /// @param line The line
    /// @return The literals' contents, in order
    static func stringLiterals(in line: String) -> [String] {
        var literals: [String] = []
        var current: String?
        var escaped = false
        var previous: Character?
        for character in line {
            defer { previous = character }
            // A // outside a string starts a comment
            if current == nil, character == "/", previous == "/" {
                break
            }
            if var text = current {
                if escaped {
                    text.append(character)
                    escaped = false
                    current = text
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    literals.append(text)
                    current = nil
                } else {
                    text.append(character)
                    current = text
                }
            } else if character == "\"" {
                current = ""
            }
        }
        return literals
    }
}
