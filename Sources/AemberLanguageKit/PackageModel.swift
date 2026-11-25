/**
    @file PackageModel.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief A project's dependencies, as one package manager reports them
    @details
    PackageGraph is what the navigator's Packages folder (and later the
    MCP tools) see of a manifest, whatever the package manager: the
    root's direct dependencies, each with its version rule as written
    and its kind, and every resolved package with its version, source,
    checkout on disk and the packages it depends on. The graph answers
    the questions the folder asks: the flat list (direct dependencies
    first, then indirect ones), a package's children for the dependency
    tree, and which packages require one. A workspace's members
    (PackageMember: Cargo workspace members, npm, pnpm and Yarn
    workspaces) are packages of their own below the root, sharing its
    lockfile, so the graph holds each one's direct dependencies too.
    Backends build it (PackageBackend.swift); nothing here runs a tool
    or reads a file. Aember gives a change its title (PackageChange's
    title), in its own words.
    PackageChange is a change to the dependencies (add, remove,
    update, change a rule, resolve), and PackageCapabilities what a
    backend can do.
*/

import Foundation

// MARK: - Version Rules

/// @brief How a direct dependency's version is chosen, as written
@frozen
public enum VersionRule: Equatable, Sendable {

    /// From a version up to the next major (SwiftPM's from:)
    case upToNextMajor(String)

    /// From a version up to the next minor
    case upToNextMinor(String)

    /// Exactly one version
    case exact(String)

    /// From a version up to, not including, another
    case range(String, String)

    /// A git branch
    case branch(String)

    /// A git revision
    case revision(String)

    /// A folder on disk, as written (relative to the manifest or not)
    case path(String)

    /// An npm or Cargo requirement string, as written (^1.2, ~0.4, *)
    case requirement(String)

    /// @brief The rule as the navigator shows it, beside the version.
    /// @detail
    /// SwiftPM's rules read like the manifest (from: 1.1.0,
    /// branch: main); requirement strings are shown as written.
    /// These are the package managers' own words, not translated.
    public var displayText: String {
        switch self {
        case .upToNextMajor(let version):
            return "from: \(version)"
        case .upToNextMinor(let version):
            return "upToNextMinor: \(version)"
        case .exact(let version):
            return "exact: \(version)"
        case .range(let lower, let upper):
            return "\(lower)..<\(upper)"
        case .branch(let branch):
            return "branch: \(branch)"
        case .revision(let revision):
            return "revision: \(revision.prefix(7))"
        case .path(let path):
            return "path \(path)"
        case .requirement(let requirement):
            return requirement
        }
    }
}

// MARK: - Dependencies

/// @brief What a direct dependency is for
@frozen
public enum DependencyKind: String, Equatable, CaseIterable, Sendable {

    /// Built into the package
    case normal

    /// Only for development and tests (npm, Cargo)
    case dev

    /// Only for build scripts (Cargo)
    case build

    /// Installed when it can be (npm's optionalDependencies)
    case optional
}

/// @brief Where a resolved package comes from
@frozen
public enum PackageSource: Equatable, Sendable {

    /// A registry: crates.io, npm's, or a Swift package registry, by
    /// its URL when known
    case registry(String?)

    /// A git repository, by URL
    case git(String)

    /// A folder on disk
    case path(String)

    /// The tool didn't say
    case unknown
}

/// @brief One dependency the root manifest declares
public struct PackageDependency: Equatable, Sendable {

    /// The name the navigator shows (SwiftPM's identity, a crate's or
    /// npm package's name)
    public var name: String

    /// The version rule, as written; nil if the manifest has none
    public var rule: VersionRule?

    /// What the dependency is for
    public var kind: DependencyKind = .normal

    /// Where it comes from as the manifest says: a URL, a path, or a
    /// registry identity
    public var location: String?

    /// The resolved package's id in the graph; nil if not resolved
    public var resolvedID: String?

    /// @brief A dependency.
    /// @param name Its name
    /// @param rule Its version rule, as written
    /// @param kind What it is for
    /// @param location Where it comes from, as the manifest says
    /// @param resolvedID The resolved package's id
    /// @return The dependency
    public init(name: String, rule: VersionRule? = nil, kind: DependencyKind = .normal, location: String? = nil, resolvedID: String? = nil) {
        self.name = name
        self.rule = rule
        self.kind = kind
        self.location = location
        self.resolvedID = resolvedID
    }
}

/// @brief One package in the resolved graph
public struct ResolvedPackage: Equatable, Sendable {

    /// Unique in its graph: SwiftPM's identity, Cargo's "name version",
    /// the lockfile path of an npm package
    public var id: String

    /// The name the navigator shows
    public var name: String

    /// The resolved version, if it has one (a branch pin has none)
    public var version: String?

    /// The git revision, if pinned to one
    public var revision: String?

    /// The git branch, if pinned to one
    public var branch: String?

    /// Where it comes from
    public var source: PackageSource = .unknown

    /// Its files on disk, if checked out
    public var checkout: URL?

    /// The ids of the packages it depends on, in the tool's order
    public var dependencies: [String] = []

    /// While parked at a moment: the version checked out now, when it
    /// differs from the one then ("1.4.0 then, 1.5.0 now")
    public var versionNow: String?

    /// While parked at a moment: whether what it depended on then is
    /// unknown (no lockfile edges then, and another version now)
    public var dependenciesUnknown = false

    /// @brief A resolved package.
    /// @param id Its id in the graph
    /// @param name Its name
    /// @param version Its version
    /// @param revision Its git revision
    /// @param branch Its git branch
    /// @param source Where it comes from
    /// @param checkout Its files on disk
    /// @param dependencies The ids it depends on
    /// @param versionNow The version now, while parked
    /// @param dependenciesUnknown Whether its dependencies then are unknown
    /// @return The package
    public init(id: String, name: String, version: String? = nil, revision: String? = nil, branch: String? = nil, source: PackageSource = .unknown, checkout: URL? = nil, dependencies: [String] = [], versionNow: String? = nil, dependenciesUnknown: Bool = false) {
        self.id = id
        self.name = name
        self.version = version
        self.revision = revision
        self.branch = branch
        self.source = source
        self.checkout = checkout
        self.dependencies = dependencies
        self.versionNow = versionNow
        self.dependenciesUnknown = dependenciesUnknown
    }

    /// @brief The version as the navigator shows it: the version, else
    /// the branch, else the revision's first seven characters.
    public var displayVersion: String? {
        if let version {
            return version
        }
        if let branch {
            return branch
        }
        return revision.map { String($0.prefix(7)) }
    }

    /// @brief The repository's web address, for Open Repository: a git
    /// source, or nil.
    public var repositoryURL: URL? {
        guard case .git(let location) = source else { return nil }
        var text = location
        if text.hasSuffix(".git") {
            text.removeLast(4)
        }
        guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true
        else {
            return nil
        }
        return url
    }
}

// MARK: - Workspace Members

/// @brief One member of a workspace: a package of its own in a folder
/// below the root, resolved through the root's lockfile
public struct PackageMember: Equatable, Sendable {

    /// The member's package name (a crate's, package.json's), or its
    /// folder's when it has none
    public var name: String

    /// Its folder, relative to the root ("crates/core")
    public var path: String

    /// Its manifest
    public var manifestURL: URL

    /// Its direct dependencies, resolved in the graph's packages
    public var dependencies: [PackageDependency]

    /// The member's own id among the graph's packages, when the
    /// lockfile lists it as one (an npm workspace's link, a Cargo
    /// member), so it isn't listed again as an indirect package
    public var packageID: String?

    /// Whether package.json names the member, which Yarn's workspace
    /// command needs
    public var hasName = true

    /// @brief A member.
    /// @param name Its package name
    /// @param path Its folder, relative to the root
    /// @param manifestURL Its manifest
    /// @param dependencies Its direct dependencies
    /// @param packageID Its id among the graph's packages
    /// @param hasName Whether its manifest names it
    /// @return The member
    public init(name: String, path: String, manifestURL: URL, dependencies: [PackageDependency], packageID: String? = nil, hasName: Bool = true) {
        self.name = name
        self.path = path
        self.manifestURL = manifestURL
        self.dependencies = dependencies
        self.packageID = packageID
        self.hasName = hasName
    }

    /// @brief A direct dependency by name.
    /// @param name The dependency's name
    /// @param kind Its kind, or nil for any
    /// @return The first such dependency, or nil
    public func dependency(named name: String, kind: DependencyKind? = nil) -> PackageDependency? {
        dependencies.first { $0.name == name && (kind == nil || $0.kind == kind) }
    }
}

// MARK: - The Graph

/// @brief One manifest's dependencies and their resolved packages
public struct PackageGraph: Equatable, Sendable {

    /// The root package's name, as its manifest gives it
    public var rootName: String

    /// The direct dependencies, in manifest order
    public var dependencies: [PackageDependency]

    /// Every resolved package but the root
    public var packages: [ResolvedPackage]

    /// Whether there is a lockfile (or resolved state) at all; false
    /// shows the direct dependencies as not resolved yet
    public var isResolved: Bool

    /// Whether the packages' dependencies are known; false when only
    /// the pins are (SwiftPM before its first resolve)
    public var hasEdges: Bool

    /// Whether the root manifest declares no package of its own (a
    /// Cargo virtual workspace), so its members' dependencies stand in
    /// for the direct ones and can't be changed through it
    public var isWorkspaceOnly: Bool

    /// The root package's targets a dependency's product can be added
    /// to, in manifest order (SwiftPM); empty for other backends
    public var targets: [String] = []

    /// The workspace's members, by path; empty without a workspace
    public var members: [PackageMember] = []

    /// @brief A member by its path.
    /// @param path The member's folder, relative to the root
    /// @return The member, or nil
    public func member(_ path: String) -> PackageMember? {
        members.first { $0.path == path }
    }

    /// @brief The direct dependencies of the root, or of a member.
    /// @param member The member's path, or nil for the root
    /// @return The dependencies
    public func dependencies(of member: String?) -> [PackageDependency] {
        member.map { self.member($0)?.dependencies ?? [] } ?? dependencies
    }

    /// @brief Creates a graph.
    /// @param rootName The root package's name
    /// @param dependencies The direct dependencies, in manifest order
    /// @param packages The resolved packages, root left out
    /// @param isResolved Whether there is a lockfile
    /// @param hasEdges Whether the packages' dependencies are known
    /// @param isWorkspaceOnly Whether the manifest has no package
    public init(
        rootName: String,
        dependencies: [PackageDependency],
        packages: [ResolvedPackage] = [],
        isResolved: Bool = true,
        hasEdges: Bool = true,
        isWorkspaceOnly: Bool = false
    ) {
        self.rootName = rootName
        self.dependencies = dependencies
        self.packages = packages
        self.isResolved = isResolved
        self.hasEdges = hasEdges
        self.isWorkspaceOnly = isWorkspaceOnly
    }

    /// @brief A direct dependency by name.
    /// @param name The dependency's name
    /// @param kind Its kind, or nil for any
    /// @return The first such dependency, or nil
    public func dependency(named name: String, kind: DependencyKind? = nil) -> PackageDependency? {
        dependencies.first { $0.name == name && (kind == nil || $0.kind == kind) }
    }

    /// @brief A resolved package by id.
    /// @param id The package's id
    /// @return The package, or nil
    public func package(_ id: String) -> ResolvedPackage? {
        packages.first { $0.id == id }
    }

    /// @brief The ids of the root's direct dependencies that resolved.
    public var directIDs: Set<String> {
        Set(dependencies.compactMap(\.resolvedID))
    }

    /// @brief The ids of the direct dependencies of the root and every
    /// member, and of the members themselves.
    public var workspaceIDs: Set<String> {
        directIDs
            .union(members.flatMap { $0.dependencies.compactMap(\.resolvedID) })
            .union(members.compactMap(\.packageID))
    }

    /// @brief The packages no direct dependency (of the root or a
    /// member) or member is, sorted by name (then version), for the
    /// flat view's dimmed rows.
    public var indirectPackages: [ResolvedPackage] {
        let direct = workspaceIDs
        return packages.filter { !direct.contains($0.id) }.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return ($0.version ?? "") < ($1.version ?? "")
        }
    }

    /// @brief The packages one package depends on, for the tree.
    /// @param id The package's id
    /// @return Its dependencies that are in the graph, in its order
    public func children(of id: String) -> [ResolvedPackage] {
        guard let package = package(id) else { return [] }
        return package.dependencies.compactMap { self.package($0) }
    }

    /// @brief The names of what requires a package: the root, when it
    /// is a direct dependency, then the packages that depend on it.
    /// @param id The package's id
    /// @return The names, root first, the rest sorted; empty without
    /// edges
    public func requiredBy(_ id: String) -> [String] {
        var names: [String] = []
        if directIDs.contains(id) {
            names.append(rootName)
        }
        var others = members.filter { $0.dependencies.contains { $0.resolvedID == id } }.map(\.name)
        if hasEdges {
            let memberIDs = Set(members.compactMap(\.packageID))
            others += packages.filter { $0.dependencies.contains(id) && !memberIDs.contains($0.id) }.map(\.name)
        }
        var seen = Set(names)
        names += others.filter { seen.insert($0).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return names
    }

    /// @brief The packages that depend on one, for Required By's
    /// submenu.
    /// @param id The package's id
    /// @return The packages, sorted by name
    public func dependents(of id: String) -> [ResolvedPackage] {
        packages.filter { $0.dependencies.contains(id) }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// @brief The way from a direct dependency down to a package, for
    /// selecting it in the tree.
    /// @detail
    /// Breadth first from the direct dependencies, so the shortest way
    /// wins.
    /// @param id The package's id
    /// @return The ids from a direct dependency to the package, both
    /// included, or nil if no direct dependency leads to it
    public func path(to id: String) -> [String]? {
        var queue: [[String]] = dependencies.compactMap(\.resolvedID).map { [$0] }
        var seen = Set(queue.compactMap(\.first))
        var index = 0
        while index < queue.count {
            let path = queue[index]
            index += 1
            guard let last = path.last else { continue }
            if last == id {
                return path
            }
            for child in package(last)?.dependencies ?? [] where seen.insert(child).inserted {
                queue.append(path + [child])
            }
        }
        return nil
    }
}

// MARK: - Changes

/// @brief A package to add: what the user typed or chose
public struct PackageSpec: Equatable, Sendable {

    /// A package name (crate, npm package), a git URL, a folder, or a
    /// Swift registry identity (scope.name)
    public var name: String

    /// The version rule, or nil for the package manager's default (the
    /// latest version)
    public var rule: VersionRule?

    /// For SwiftPM: the products to add to targets, as (product,
    /// target)
    public var products: [(product: String, target: String)] = []

    /// @brief A package to add.
    /// @param name What the user typed or chose
    /// @param rule Its version rule, nil for the latest
    /// @param products For SwiftPM, (product, target) pairs
    /// @return The spec
    public init(name: String, rule: VersionRule? = nil, products: [(product: String, target: String)] = []) {
        self.name = name
        self.rule = rule
        self.products = products
    }

    public static func == (lhs: PackageSpec, rhs: PackageSpec) -> Bool {
        lhs.name == rhs.name && lhs.rule == rhs.rule
            && lhs.products.map(\.product) == rhs.products.map(\.product)
            && lhs.products.map(\.target) == rhs.products.map(\.target)
    }
}

/// @brief One change to a manifest's dependencies
@frozen
public enum PackageChange: Equatable, Sendable {

    /// Adds a dependency of a kind
    case add(PackageSpec, kind: DependencyKind)

    /// Removes a direct dependency, by name and kind
    case remove(name: String, kind: DependencyKind)

    /// Updates packages to the newest versions their rules allow, by
    /// direct dependency name; [] updates all
    case update(names: [String])

    /// Gives a direct dependency another version rule
    case changeRule(name: String, kind: DependencyKind, rule: VersionRule)

    /// Resolves and fetches what the manifest asks for
    case resolve

    /// The capability the change needs
    public var capability: PackageCapabilities {
        switch self {
        case .add:
            return .add
        case .remove:
            return .remove
        case .update:
            return .update
        case .changeRule:
            return .changeRule
        case .resolve:
            return .resolve
        }
    }
}

/// @brief What a backend can change
public struct PackageCapabilities: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    /// @brief Capabilities from their bits.
    /// @param rawValue The bits
    /// @return The capabilities
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let add = PackageCapabilities(rawValue: 1 << 0)
    public static let remove = PackageCapabilities(rawValue: 1 << 1)
    public static let update = PackageCapabilities(rawValue: 1 << 2)
    public static let changeRule = PackageCapabilities(rawValue: 1 << 3)
    public static let resolve = PackageCapabilities(rawValue: 1 << 4)

    /// Every change
    public static let all: PackageCapabilities = [.add, .remove, .update, .changeRule, .resolve]
}

// MARK: - Tools

/// @brief Whether a package manager's tool can be run
@frozen
public enum PackageToolStatus: Equatable, Sendable {

    /// Found, at a path
    case available(URL)

    /// Not found
    case missing

    /// Whether the tool was found
    public var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }
}
