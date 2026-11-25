/**
    @file CargoBackend.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Cargo's dependencies
    @details
    Reads a Cargo.toml's dependencies without the network: the direct
    ones from `cargo metadata --no-deps --offline` (the full metadata
    needs every crate's manifest, so it fails offline until they are
    downloaded), and the resolved graph from Cargo.lock, read here.
    Registry crates are found in Cargo's registry sources
    ($CARGO_HOME/registry/src), git ones in its git checkouts, path ones
    where the manifest says. The parsers are static so tests feed them
    saved output.

    A workspace's members (the other packages cargo metadata lists)
    are the graph's members, each with its own dependencies, resolved
    through the shared Cargo.lock; a virtual workspace (a [workspace]
    without a [package]) has members only.

    Changes run `cargo add`, `cargo remove`, `cargo update` and
    `cargo fetch`; a member's add, remove and rule change take
    `--package <member>`. A virtual workspace's dependencies belong to
    its members, so only updating and resolving work through its root.
*/

import Foundation
import AemberLanguageKit

/// @brief Cargo, for a Cargo.toml
final class CargoBackend: PackageBackend {

    static let identifier = "cargo"
    static let displayName = "Cargo"
    static let toolName = "cargo"
    static var installHint: String {
        PackStrings.text("Install Rust with rustup, from rustup.rs.").localized
    }

    /// Cargo.toml and Cargo.lock, watched for changes
    static let packageFileNames = ["Cargo.toml", "Cargo.lock"]

    /// Normal, dev, build and optional dependencies
    static let dependencyKinds: [DependencyKind] = [.normal, .dev, .build, .optional]

    /// @brief crates.io, for the Add Package sheet.
    /// @return The source
    static func searchSource() -> PackageSearchSource? {
        CratesIOSearch()
    }

    static func manifest(in folder: URL) -> URL? {
        let url = folder.appendingPathComponent("Cargo.toml")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    let manifestURL: URL
    let runner: PackageToolRunner

    init(manifestURL: URL, runner: PackageToolRunner) {
        self.manifestURL = manifestURL
        self.runner = runner
    }

    var lockfileURLs: [URL] {
        [folder.appendingPathComponent("Cargo.lock")]
    }

    func checkTool() -> PackageToolStatus {
        runner.find(Self.toolName).map { .available($0) } ?? .missing
    }

    func readGraph() throws -> PackageGraph {
        let metadata = try Self.parseMetadata(
            runTool(runner, ["metadata", "--format-version", "1", "--no-deps", "--offline"]),
            manifest: manifestURL
        )
        let lockURL = lockfileURLs[0]
        var lock: [LockPackage]?
        if let text = try? String(contentsOf: lockURL, encoding: .utf8) {
            lock = Self.parseLock(text)
        }
        return Self.graph(
            metadata: metadata,
            lock: lock,
            cargoHome: Self.cargoHome()
        )
    }

    func declarationLine(of dependency: PackageDependency, in manifest: String) -> Int? {
        Self.declarationLine(of: dependency, in: manifest)
    }

    // MARK: - Changes

    func command(for change: PackageChange, graph: PackageGraph, manifest: String, member: PackageMember?) throws -> PackageCommand {
        guard capabilities(for: graph, member: member?.path).contains(change.capability) else {
            throw PackageCommand.unsupported(change, by: Self.displayName)
        }
        let command = try rootCommand(for: change, graph: graph, member: member)
        guard let member else { return command }
        switch change {
        case .add, .remove, .changeRule:
            let package = ["--package", try PackageCommand.checked(member.name)]
            return PackageCommand(steps: command.steps.map { BuildStep(executable: $0.executable, arguments: $0.arguments + package) })
        case .update, .resolve:
            return command
        }
    }

    /// @brief The command for a change, before a member's --package.
    /// @param change The change
    /// @param graph The graph
    /// @param member The member whose dependency it is, if any
    /// @return The command
    private func rootCommand(for change: PackageChange, graph: PackageGraph, member: PackageMember?) throws -> PackageCommand {
        switch change {
        case .add(let spec, let kind):
            var arguments = ["add"]
            let name = try PackageCommand.checked(spec.name)
            switch spec.rule {
            case .path(let path)?:
                arguments += ["--path", try PackageCommand.checked(path)]
            case .branch(let branch)?:
                arguments += ["--git", name, "--branch", try PackageCommand.checked(branch)]
            case .revision(let revision)?:
                arguments += ["--git", name, "--rev", try PackageCommand.checked(revision)]
            case nil:
                arguments.append(name)
            case let rule?:
                guard let requirement = rule.requirementString(exactPrefix: "=") else {
                    throw PackageCommand.unsupported(change, by: Self.displayName)
                }
                arguments.append(name + "@" + (try PackageCommand.checked(requirement)))
            }
            return PackageCommand(steps: [step(arguments + Self.kindArguments(kind))])

        case .remove(let name, let kind):
            var arguments = ["remove", try PackageCommand.checked(name)]
            if kind == .dev || kind == .build {
                arguments += Self.kindArguments(kind)
            }
            return PackageCommand(steps: [step(arguments)])

        case .update(let names):
            let crates = try names.map { try PackageCommand.checked(Self.crateName(of: $0, in: graph)) }
            return PackageCommand(steps: [step(["update"] + crates)])

        case .changeRule(let name, let kind, let rule):
            guard let dependency = dependency(named: name, kind: kind, in: graph, member: member), canChangeRule(of: dependency),
                  let requirement = rule.requirementString(exactPrefix: "=")
            else {
                throw PackageCommand.unsupported(change, by: Self.displayName)
            }
            let crate = dependency.resolvedID.flatMap { graph.package($0)?.name } ?? name
            var arguments = ["add", try PackageCommand.checked(crate) + "@" + (try PackageCommand.checked(requirement))]
            if crate != name {
                arguments += ["--rename", try PackageCommand.checked(name)]
            }
            if kind == .dev || kind == .build {
                arguments += Self.kindArguments(kind)
            }
            return PackageCommand(steps: [step(arguments)])

        case .resolve:
            return PackageCommand(steps: [step(["fetch"])])
        }
    }

    /// @brief cargo add's flags for a kind.
    /// @param kind The dependency's kind
    /// @return --dev, --build, --optional, or none
    static func kindArguments(_ kind: DependencyKind) -> [String] {
        switch kind {
        case .normal:
            return []
        case .dev:
            return ["--dev"]
        case .build:
            return ["--build"]
        case .optional:
            return ["--optional"]
        }
    }

    /// @brief The crate a direct dependency is, for cargo update and a
    /// renamed dependency's cargo add: its resolved package's name,
    /// else the name as written.
    /// @param name The dependency's key in Cargo.toml
    /// @param graph The graph
    /// @return The crate's name
    static func crateName(of name: String, in graph: PackageGraph) -> String {
        graph.dependency(named: name)?.resolvedID.flatMap { graph.package($0)?.name } ?? name
    }

    /// @brief Cargo's home: $CARGO_HOME, else ~/.cargo.
    /// @return The folder
    static func cargoHome() -> URL {
        if let home = ProcessInfo.processInfo.environment["CARGO_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cargo")
    }

    // MARK: - cargo metadata

    /// @brief The root package and the workspace's members, as cargo
    /// metadata --no-deps says
    struct Metadata: Equatable {

        /// The root package's name, or a virtual workspace's folder's
        var name: String

        /// The root package as Cargo.lock names it ("name version");
        /// none for a virtual workspace
        var roots: [String]

        /// The root's dependencies, in manifest order; each name is the
        /// key in Cargo.toml (the rename, if any)
        var dependencies: [PackageDependency]

        /// The crate names of the dependencies, by key
        var crateNames: [String: String]

        /// Whether the manifest has no package of its own, only
        /// workspace members
        var isVirtual = false

        /// The workspace's other packages
        var members: [Member] = []

        /// @brief One workspace member
        struct Member: Equatable {

            /// The crate's name
            var name: String

            /// Its version, for its Cargo.lock id
            var version: String

            /// Its folder, relative to the root's
            var path: String

            /// Its Cargo.toml
            var manifestURL: URL

            /// Its dependencies, as the root's
            var dependencies: [PackageDependency]

            /// Their crate names, by key
            var crateNames: [String: String]

            /// "name version", as Cargo.lock names it
            var id: String {
                "\(name) \(version)"
            }
        }
    }

    /// @brief Reads cargo metadata's JSON for the package at a manifest.
    /// @detail
    /// With --no-deps, the packages listed are the workspace's
    /// packages; the root is the one whose manifest is this one, and
    /// the others are members. A virtual workspace (a [workspace]
    /// without a [package]) has no root package and no dependencies of
    /// its own.
    /// @param data The JSON
    /// @param manifest The Cargo.toml
    /// @return The root package and the members
    /// @throws PackageError.unreadable if it isn't cargo metadata's
    static func parseMetadata(_ data: Data, manifest: URL) throws -> Metadata {
        // l10n-exempt: a command's name
        let command = "cargo metadata"
        let object = try PackageJSON.object(data, name: command)
        guard let packages = object["packages"] as? [[String: Any]] else {
            throw PackageError.unreadable(command)
        }
        func manifestPath(_ package: [String: Any]) -> String? {
            (package["manifest_path"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        }
        let target = manifest.standardizedFileURL.resolvingSymlinksInPath().path
        let root = packages.first { manifestPath($0) == target }
        let folder = manifest.deletingLastPathComponent()
        let name = root?["name"] as? String ?? folder.lastPathComponent
        let roots = root.flatMap { package -> String? in
            guard let name = package["name"] as? String else { return nil }
            return "\(name) \(package["version"] as? String ?? "")"
        }.map { [$0] } ?? []
        let own: (dependencies: [PackageDependency], crateNames: [String: String]) = root.map { dependencies(of: $0, folder: folder) } ?? ([], [:])
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let members = packages.compactMap { package -> Metadata.Member? in
            guard let path = manifestPath(package), path != target, let memberName = package["name"] as? String else { return nil }
            let memberFolder = URL(fileURLWithPath: path).deletingLastPathComponent()
            var relative = memberFolder.path
            if relative.hasPrefix(base + "/") {
                relative = String(relative.dropFirst(base.count + 1))
            }
            let read = dependencies(of: package, folder: memberFolder)
            return Metadata.Member(
                name: memberName,
                version: package["version"] as? String ?? "",
                path: relative,
                manifestURL: URL(fileURLWithPath: path),
                dependencies: read.dependencies,
                crateNames: read.crateNames
            )
        }.sorted { $0.path < $1.path }
        return Metadata(
            name: name,
            roots: roots,
            dependencies: own.dependencies,
            crateNames: own.crateNames,
            isVirtual: root == nil,
            members: members
        )
    }

    /// @brief One package's dependencies from cargo metadata.
    /// @param package The package's object
    /// @param folder Its folder, for path dependencies
    /// @return Its dependencies in manifest order, the same crate for
    /// several targets once, and their crate names by key
    static func dependencies(of package: [String: Any], folder: URL) -> (dependencies: [PackageDependency], crateNames: [String: String]) {
        var crateNames: [String: String] = [:]
        var seen = Set<String>()
        var dependencies: [PackageDependency] = []
        let entries = package["dependencies"] as? [[String: Any]] ?? []
        for entry in entries {
            guard let crate = entry["name"] as? String else { continue }
            let key = entry["rename"] as? String ?? crate
            let kind: DependencyKind
            switch entry["kind"] as? String {
            case "dev":
                kind = .dev
            case "build":
                kind = .build
            default:
                kind = (entry["optional"] as? Bool == true) ? .optional : .normal
            }
            // The same crate for several targets is one dependency
            guard seen.insert("\(key) \(kind.rawValue)").inserted else { continue }
            crateNames[key] = crate
            let path = entry["path"] as? String
            let requirement = entry["req"] as? String ?? "*"
            let rule: VersionRule
            if let path, requirement == "*" {
                rule = .path(URL(fileURLWithPath: path).packageDisplayPath(relativeTo: folder))
            } else {
                rule = .requirement(requirement)
            }
            dependencies.append(PackageDependency(
                name: key,
                rule: rule,
                kind: kind,
                location: path ?? entry["source"] as? String,
                resolvedID: nil
            ))
        }
        return (dependencies, crateNames)
    }

    // MARK: - Cargo.lock

    /// @brief One [[package]] in Cargo.lock
    struct LockPackage: Equatable {
        var name: String
        var version: String
        var source: String?
        /// As written: "name", "name version" or "name version (source)"
        var dependencies: [String]

        /// "name version", unique in a lockfile
        var id: String {
            "\(name) \(version)"
        }
    }

    /// @brief Reads Cargo.lock's packages.
    /// @detail
    /// Cargo writes the file the same way every time: [[package]]
    /// tables of name, version, source, checksum and a dependencies
    /// array one string per line. Only those are read.
    /// @param text The file
    /// @return Its packages, in order
    static func parseLock(_ text: String) -> [LockPackage] {
        var packages: [LockPackage] = []
        var current: LockPackage?
        var inDependencies = false
        func finish() {
            if let current {
                packages.append(current)
            }
            current = nil
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "[[package]]" {
                finish()
                current = LockPackage(name: "", version: "", source: nil, dependencies: [])
                inDependencies = false
                continue
            }
            if line.hasPrefix("[") && !inDependencies {
                finish()
                continue
            }
            guard current != nil else { continue }
            if inDependencies {
                if line.hasPrefix("]") {
                    inDependencies = false
                } else if let value = quoted(line) {
                    current?.dependencies.append(value)
                }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "name":
                current?.name = quoted(value) ?? value
            case "version":
                current?.version = quoted(value) ?? value
            case "source":
                current?.source = quoted(value)
            case "dependencies":
                if value.hasPrefix("[") && value.hasSuffix("]") {
                    current?.dependencies = value.dropFirst().dropLast()
                        .split(separator: ",")
                        .compactMap { quoted(String($0).trimmingCharacters(in: .whitespaces)) }
                } else {
                    inDependencies = true
                }
            default:
                break
            }
        }
        finish()
        return packages.filter { !$0.name.isEmpty }
    }

    /// @brief The contents of a TOML basic string.
    /// @param text "text", with a trailing comma or not
    /// @return The contents, or nil if it isn't quoted
    private static func quoted(_ text: String) -> String? {
        var value = text
        if value.hasSuffix(",") {
            value.removeLast()
        }
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            return nil
        }
        return String(value.dropFirst().dropLast())
    }

    // MARK: - The Graph

    /// @brief Puts the root's dependencies and Cargo.lock together.
    /// @detail
    /// The root is the lock's package with the root's name and version
    /// and no source; its dependencies resolve the direct ones, and it
    /// isn't a package of the graph. Each member is a package (a folder
    /// one) and the graph's member, whose dependencies its lock entry's
    /// resolve. A dependency written by name alone is the lock's only
    /// package of that name.
    /// @param metadata The root package
    /// @param lock Cargo.lock's packages, nil without the file
    /// @param cargoHome Cargo's home, for finding sources
    /// @return The graph
    static func graph(
        metadata: Metadata,
        lock: [LockPackage]?,
        cargoHome: URL
    ) -> PackageGraph {
        guard let lock else {
            var graph = PackageGraph(
                rootName: metadata.name,
                dependencies: metadata.dependencies,
                isResolved: false,
                hasEdges: false,
                isWorkspaceOnly: metadata.isVirtual
            )
            graph.members = metadata.members.map {
                PackageMember(name: $0.name, path: $0.path, manifestURL: $0.manifestURL, dependencies: $0.dependencies)
            }
            return graph
        }
        var byName: [String: [LockPackage]] = [:]
        for package in lock {
            byName[package.name, default: []].append(package)
        }
        func resolve(_ reference: String) -> String? {
            let parts = reference.split(separator: " ").map(String.init)
            guard let name = parts.first else { return nil }
            if parts.count >= 2 {
                return "\(name) \(parts[1])"
            }
            return byName[name]?.count == 1 ? byName[name]?.first?.id : nil
        }
        let roots = Set(metadata.roots)
        let rootPackages = lock.filter { $0.source == nil && roots.contains($0.id) }
        let rootIDs = rootPackages.flatMap(\.dependencies).compactMap(resolve)
        let membersByName = Dictionary(metadata.members.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let registrySources = (try? FileManager.default.contentsOfDirectory(
            at: cargoHome.appendingPathComponent("registry/src"),
            includingPropertiesForKeys: nil
        )) ?? []
        let directPaths = Dictionary(
            metadata.dependencies.compactMap { dependency -> (String, String)? in
                // A path dependency's location is its folder; others'
                // is their registry or git source
                guard let path = dependency.location, path.hasPrefix("/") else {
                    return nil
                }
                return (metadata.crateNames[dependency.name] ?? dependency.name, path)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let packages = lock.filter { !roots.contains($0.id) || $0.source != nil }.map { package -> ResolvedPackage in
            var resolved = ResolvedPackage(
                id: package.id,
                name: package.name,
                version: package.version,
                dependencies: package.dependencies.compactMap(resolve)
            )
            if let source = package.source {
                if source.hasPrefix("git+") {
                    let (url, revision) = gitSource(source)
                    resolved.source = .git(url)
                    resolved.revision = revision
                    resolved.checkout = gitCheckout(
                        name: URL(string: url)?.deletingPathExtension().lastPathComponent ?? package.name,
                        revision: revision,
                        cargoHome: cargoHome
                    )
                } else {
                    resolved.source = .registry(source.replacingOccurrences(of: "registry+", with: ""))
                    resolved.checkout = registrySources
                        .map { $0.appendingPathComponent("\(package.name)-\(package.version)") }
                        .first { FileManager.default.fileExists(atPath: $0.path) }
                }
            } else if let member = membersByName[package.name], member.version == package.version {
                resolved.source = .path(member.path)
                resolved.checkout = member.manifestURL.deletingLastPathComponent()
            } else if let path = directPaths[package.name] {
                resolved.source = .path(path)
                resolved.checkout = URL(fileURLWithPath: path)
            } else {
                resolved.source = .path("")
            }
            return resolved
        }

        func resolved(_ dependencies: [PackageDependency], crateNames: [String: String], by ids: [String]) -> [PackageDependency] {
            dependencies.map { dependency in
                var resolved = dependency
                let crate = crateNames[dependency.name] ?? dependency.name
                resolved.resolvedID = ids.first { $0.hasPrefix(crate + " ") }
                    ?? (byName[crate]?.count == 1 ? byName[crate]?.first?.id : nil)
                return resolved
            }
        }
        let dependencies = resolved(metadata.dependencies, crateNames: metadata.crateNames, by: rootIDs)
        var graph = PackageGraph(
            rootName: metadata.name,
            dependencies: dependencies,
            packages: packages,
            isResolved: true,
            hasEdges: true,
            isWorkspaceOnly: metadata.isVirtual
        )
        let packageIDs = Set(packages.map(\.id))
        graph.members = metadata.members.map { member in
            let ids = lock.first { $0.source == nil && $0.id == member.id }?.dependencies.compactMap(resolve) ?? []
            return PackageMember(
                name: member.name,
                path: member.path,
                manifestURL: member.manifestURL,
                dependencies: resolved(member.dependencies, crateNames: member.crateNames, by: ids),
                packageID: packageIDs.contains(member.id) ? member.id : nil
            )
        }
        return graph
    }

    /// @brief A git source's repository and revision.
    /// @param source "git+https://host/repo?branch=main#0123abc"
    /// @return The URL without query and revision, and the revision
    static func gitSource(_ source: String) -> (url: String, revision: String?) {
        var text = String(source.dropFirst("git+".count))
        var revision: String?
        if let hash = text.firstIndex(of: "#") {
            revision = String(text[text.index(after: hash)...])
            text = String(text[..<hash])
        }
        if let query = text.firstIndex(of: "?") {
            text = String(text[..<query])
        }
        return (text, revision)
    }

    /// @brief Where Cargo checked out a git dependency:
    /// git/checkouts/<name>-<hash>/<short revision>.
    /// @param name The repository's name
    /// @param revision The revision
    /// @param cargoHome Cargo's home
    /// @return The checkout, or nil if not found
    static func gitCheckout(name: String, revision: String?, cargoHome: URL) -> URL? {
        guard let revision else { return nil }
        let checkouts = cargoHome.appendingPathComponent("git/checkouts")
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: checkouts,
            includingPropertiesForKeys: nil
        )) ?? []
        let short = String(revision.prefix(7))
        return folders.filter { $0.lastPathComponent.hasPrefix(name + "-") }
            .map { $0.appendingPathComponent(short) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - The Declaration

    /// @brief The line declaring a dependency in Cargo.toml.
    /// @detail
    /// In a dependencies table of its kind ([dependencies],
    /// [dev-dependencies], [build-dependencies], or a target's), the
    /// line whose key is the dependency's, or the header
    /// [dependencies.<key>].
    /// @param dependency The dependency
    /// @param manifest Cargo.toml's text
    /// @return The 1-based line, or nil
    static func declarationLine(of dependency: PackageDependency, in manifest: String) -> Int? {
        let table: String
        switch dependency.kind {
        case .dev:
            table = "dev-dependencies"
        case .build:
            table = "build-dependencies"
        case .normal, .optional:
            table = "dependencies"
        }
        let key = dependency.name
        var inTable = false
        for (index, rawLine) in manifest.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                if header == "\(table).\(key)" || header.hasSuffix(".\(table).\(key)") {
                    return index + 1
                }
                inTable = header == table || header.hasSuffix(".\(table)")
                continue
            }
            guard inTable else { continue }
            for candidate in [key, "\"\(key)\""] where line.hasPrefix(candidate) {
                let rest = line.dropFirst(candidate.count).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("=") || rest.hasPrefix(".") {
                    return index + 1
                }
            }
        }
        return nil
    }
}
