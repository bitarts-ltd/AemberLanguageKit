/**
    @file PackageBackend.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Package managers behind one protocol, and running their tools
    @details
    A PackageBackend is one package manager's view of one manifest: it
    says which manifest it handles in a folder, whether its tool is
    installed, and reads the dependency graph without the network
    (readGraph). PackageBackendRegistry lists the backends and finds
    the manifests in a project's root, so a project can have several
    (a Swift package with a package.json for its website). Backends run
    their tools through a PackageToolRunner, which tests replace with
    saved output; ProcessPackageToolRunner finds the tool as builds do
    (ExecutableFinder) and runs it with a time limit. Reading blocks,
    so it happens off the main thread (ProjectPackages).

    A change to the dependencies is a PackageCommand: the tool's runs,
    which PackageChangeRunner hands to the project's BuildRunner, and
    for the one change a tool can't make (removing a Swift package) the
    manifest's text after Aember's own edit. Building a command runs
    nothing. Names and requirements that would read as options (a
    leading "-") or span lines are refused.
*/

import Foundation

// MARK: - Backends

/// @brief One package manager's view of one manifest
public protocol PackageBackend: AnyObject {

    /// "swiftpm", "cargo", "npm", "pnpm", "yarn"
    static var identifier: String { get }

    /// The name of the folder for this backend when a project has
    /// several ("Swift", "Cargo", "npm")
    static var displayName: String { get }

    /// The command line tool the backend runs ("swift", "cargo", "npm")
    static var toolName: String { get }

    /// What to install to get the tool, for the folder's tooltip when
    /// it's missing
    static var installHint: String { get }

    /// @brief The manifest this backend handles in a folder.
    /// @param folder The folder, usually the project root
    /// @return The manifest, or nil if the folder has none
    static func manifest(in folder: URL) -> URL?

    /// @brief Creates the backend for a manifest.
    /// @param manifestURL The manifest
    /// @param runner Runs the backend's tools
    init(manifestURL: URL, runner: PackageToolRunner)

    /// The manifest
    var manifestURL: URL { get }

    /// The files the backend reads the resolved graph from, whether
    /// they exist or not (Package.resolved, Cargo.lock, ...)
    var lockfileURLs: [URL] { get }

    /// @brief Whether the backend's tool is installed.
    /// @return Its status
    func checkTool() -> PackageToolStatus

    /// @brief Reads the direct dependencies and the resolved graph,
    /// without the network or a resolve.
    /// @return The graph
    /// @throws PackageError when the manifest or the tool's output
    /// can't be read
    func readGraph() throws -> PackageGraph

    /// @brief The line declaring a dependency in the manifest, for
    /// Show in Manifest.
    /// @param dependency The dependency
    /// @param manifest The manifest's text
    /// @return The 1-based line, or nil if it isn't written literally
    func declarationLine(of dependency: PackageDependency, in manifest: String) -> Int?

    /// @brief The command that makes a change.
    /// @detail
    /// With a workspace member, adding, removing and changing a rule
    /// act on the member's manifest; updating and resolving act on the
    /// whole workspace, whose lockfile is shared.
    /// @param change The change
    /// @param graph The graph last read, for the dependencies' names,
    /// kinds and locations
    /// @param manifest The text of the manifest changed (the member's,
    /// with a member)
    /// @param member The workspace member changed, or nil for the root
    /// @return The command
    /// @throws PackageError.unsupported when the backend can't make the
    /// change, .notWrittenLiterally when Aember would edit the manifest
    /// and can't find what to edit
    func command(for change: PackageChange, graph: PackageGraph, manifest: String, member: PackageMember?) throws -> PackageCommand

    /// @brief Asks which packages have newer versions and known
    /// vulnerabilities. Reaches the network; never runs on its own.
    /// @param graph The graph last read
    /// @param http The client for registries
    /// @return What was found, with what couldn't be checked
    func check(graph: PackageGraph, http: PackageHTTP) async -> PackageCheckResult

    /// @brief Where the Add Package sheet finds packages for this
    /// backend.
    /// @return The source, or nil when packages are typed by name
    static func searchSource() -> PackageSearchSource?

    /// The names of the manifests and lockfiles the backend reads, so a
    /// change to one on disk reads the graph again ("Cargo.toml",
    /// "Cargo.lock")
    static var packageFileNames: [String] { get }

    /// The kinds of dependency the Add Package sheet offers; only
    /// .normal hides its popup
    static var dependencyKinds: [DependencyKind] { get }

    /// Whether a requirement written as a bare version (1.2.3) means
    /// exactly it, as npm's does, rather than ^, as Cargo's does
    static var bareVersionIsExact: Bool { get }

    /// How the Add Package sheet asks for a package: a requirement
    /// string, or a Swift package's sources, rule kinds and products
    static var addStyle: PackageAddStyle { get }

    /// @brief Where the Add Package sheet may take a package from, for a
    /// manifest's folder; only .search hides its popup.
    /// @param folder The manifest's folder
    /// @return The sources, in the popup's order
    static func addSources(in folder: URL) -> [PackageAddSource]

    /// @brief Where the Add Package sheet finds packages from one source.
    /// @param source The source
    /// @param folder The manifest's folder, for its configuration
    /// @return The search source, or nil when the package is typed
    static func searchSource(for source: PackageAddSource, in folder: URL) -> PackageSearchSource?

    /// @brief The name a dependency at a location is known by, to find
    /// it in the graph once added.
    /// @param location A URL, path or name
    /// @return Its identity (the last path component, lowercased, without
    /// .git, by default)
    static func identity(ofLocation location: String) -> String
}

/// @brief How the Add Package sheet asks for a package
@frozen
public enum PackageAddStyle: Sendable {

    /// A name and a requirement string (^1.2, ~0.4), and a kind (Cargo,
    /// npm)
    case requirement

    /// A source (search, git URL, folder, registry), a rule kind
    /// (from:, upToNextMinor:, exact:, a range, branch, revision) with
    /// a version that must be given, and the products to add to the
    /// root's targets (SwiftPM)
    case swiftPackage
}

/// @brief Where a package to add comes from
@frozen
public enum PackageAddSource: Int, CaseIterable, Sendable {
    /// Found by searching
    case search
    /// A git repository's URL
    case url
    /// A folder on disk
    case folder
    /// A package registry, by identity
    case registry
}

/// @brief Telling a package's location apart
public enum PackageLocation {

    /// @brief Whether text is a URL rather than a name or path.
    /// @param text The text
    /// @return True for scheme://... and git@...
    public static func isURL(_ text: String) -> Bool {
        text.contains("://") || text.hasPrefix("git@")
    }

    /// @brief The name a package at a location is known by, as SwiftPM
    /// derives it: the last path component, lowercased, without .git.
    /// @param location A URL, path or name
    /// @return The identity
    public static func identity(of location: String) -> String {
        var last = location.split(separator: "/").last.map(String.init) ?? location
        if last.hasSuffix(".git") {
            last.removeLast(4)
        }
        return last.lowercased()
    }
}

extension PackageBackend {

    /// @brief By default packages are typed by name.
    /// @return nil
    public static func searchSource() -> PackageSearchSource? {
        nil
    }

    /// No files watched by default
    public static var packageFileNames: [String] {
        []
    }

    /// Only normal dependencies by default
    public static var dependencyKinds: [DependencyKind] {
        [.normal]
    }

    /// A bare version is ^ by default
    public static var bareVersionIsExact: Bool {
        false
    }

    /// A requirement string by default
    public static var addStyle: PackageAddStyle {
        .requirement
    }

    /// @brief Search only, by default.
    /// @param folder The manifest's folder
    /// @return [.search]
    public static func addSources(in folder: URL) -> [PackageAddSource] {
        [.search]
    }

    /// @brief By default, searchSource() for a search, else none.
    /// @param source The source
    /// @param folder The manifest's folder
    /// @return The search source
    public static func searchSource(for source: PackageAddSource, in folder: URL) -> PackageSearchSource? {
        source == .search ? searchSource() : nil
    }

    /// @brief The last path component, lowercased, without .git.
    /// @param location A URL, path or name
    /// @return The identity
    public static func identity(ofLocation location: String) -> String {
        PackageLocation.identity(of: location)
    }

    /// The folder the manifest is in
    public var folder: URL {
        manifestURL.deletingLastPathComponent()
    }

    /// The manifest and the lockfiles, the files a change writes
    public var packageFiles: [URL] {
        [manifestURL] + lockfileURLs
    }

    /// @brief The command for a change to the root's dependencies.
    public func command(for change: PackageChange, graph: PackageGraph, manifest: String) throws -> PackageCommand {
        try command(for: change, graph: graph, manifest: manifest, member: nil)
    }

    /// @brief What the backend can change in a graph.
    /// @detail
    /// Everything, but for a manifest without a package of its own (a
    /// Cargo virtual workspace), whose dependencies belong to its
    /// members: only updating and resolving. A member can change
    /// everything.
    /// @param graph The graph, or nil before one is read
    /// @param member A workspace member's path, or nil for the root
    /// @return The capabilities
    public func capabilities(for graph: PackageGraph?, member: String? = nil) -> PackageCapabilities {
        guard let graph else { return [.resolve] }
        if let member {
            return graph.member(member) == nil ? [] : .all
        }
        return graph.isWorkspaceOnly ? [.update, .resolve] : .all
    }

    /// @brief A direct dependency of the root or a member.
    /// @param name Its name
    /// @param kind Its kind
    /// @param graph The graph
    /// @param member The member, or nil for the root
    /// @return The dependency, or nil
    public func dependency(named name: String, kind: DependencyKind?, in graph: PackageGraph, member: PackageMember?) -> PackageDependency? {
        member.map { $0.dependency(named: name, kind: kind) } ?? graph.dependency(named: name, kind: kind)
    }

    /// @brief Whether a direct dependency's rule can be changed: not a
    /// path dependency's, which has none.
    /// @param dependency The dependency
    /// @return true if Edit Version Rule applies
    public func canChangeRule(of dependency: PackageDependency) -> Bool {
        if case .path = dependency.rule {
            return false
        }
        return true
    }

    /// @brief One run of the backend's tool.
    /// @param arguments The arguments
    /// @return The step
    public func step(_ arguments: [String]) -> BuildStep {
        BuildStep(executable: Self.toolName, arguments: arguments)
    }

    /// @brief Runs the backend's tool in the manifest's folder.
    /// @param runner The runner
    /// @param arguments The tool's arguments
    /// @return Its standard output
    /// @throws PackageError.toolFailed if it exits with an error
    public func runTool(_ runner: PackageToolRunner, _ arguments: [String]) throws -> Data {
        let result = try runner.run(Self.toolName, arguments: arguments, in: folder)
        guard result.status == 0 else {
            throw PackageError.toolFailed(
                command: ([Self.toolName] + arguments).joined(separator: " "),
                message: result.errorText
            )
        }
        return result.output
    }
}

// MARK: - Errors

/// @brief Why a backend couldn't read a graph
@frozen
public enum PackageError: Error, Equatable, Sendable {

    /// The tool isn't installed
    case toolMissing(String)

    /// The tool exited with an error, with what it printed
    case toolFailed(command: String, message: String)

    /// The tool ran past its time
    case timedOut(String)

    /// A file or the tool's output wasn't what the backend expects
    case unreadable(String)

    /// The backend can't make a change, and why (localized)
    case unsupported(String)

    /// Aember would edit the manifest for a change, but the dependency
    /// isn't written there in a form it can edit: its name
    case notWrittenLiterally(String)

    /// A name, version or requirement that would read as an option (it
    /// is empty, starts with "-" or spans lines): the value
    case invalidArgument(String)

    /// The package manager can't make the change: the change, and the
    /// package manager's name (Swift, Cargo, npm)
    case cannotMake(PackageChange, tool: String)
}

// MARK: - Commands

/// @brief What runs to change a manifest's dependencies
public struct PackageCommand: Equatable, Sendable {

    /// The manifest's text after Aember's own edit, written before the
    /// steps run; nil when the tool makes the whole change
    public var manifestText: String?

    /// The tool's runs, in order until one fails
    public var steps: [BuildStep]

    /// @brief A command.
    /// @param manifestText The manifest's text after Aember's edit
    /// @param steps The tool's runs
    /// @return The command
    public init(manifestText: String? = nil, steps: [BuildStep]) {
        self.manifestText = manifestText
        self.steps = steps
    }

    /// @brief The command as a shell would show it.
    public var displayString: String {
        steps.map(\.displayString).joined(separator: " && ")
    }


}

extension PackageCommand {

    /// @brief Checks a name, version or requirement before it goes on a
    /// command line.
    /// @param value The value
    /// @return The value
    /// @throws PackageError.invalidArgument if it is empty, starts with
    /// "-" or spans lines
    @discardableResult
    public static func checked(_ value: String) throws -> String {
        guard !value.isEmpty, !value.hasPrefix("-"), !value.contains(where: \.isNewline) else {
            throw PackageError.invalidArgument(value)
        }
        return value
    }

    /// @brief The error for a change a backend can't make.
    /// @param change The change
    /// @param tool The package manager's name
    /// @return The error
    public static func unsupported(_ change: PackageChange, by tool: String) -> PackageError {
        .cannotMake(change, tool: tool)
    }
}

extension VersionRule {

    /// @brief The rule as an npm or Cargo requirement string.
    /// @detail
    /// A requirement as written, from: as ^, upToNextMinor as ~, exact
    /// as =; ranges, branches, revisions and paths aren't requirements.
    /// @param exactPrefix What starts an exact version ("=" for Cargo,
    /// "" for npm)
    /// @return The requirement, or nil
    public func requirementString(exactPrefix: String) -> String? {
        switch self {
        case .requirement(let text):
            return text
        case .upToNextMajor(let version):
            return "^" + version
        case .upToNextMinor(let version):
            return "~" + version
        case .exact(let version):
            return exactPrefix + version
        case .range, .branch, .revision, .path:
            return nil
        }
    }
}

// MARK: - Running Tools

/// @brief What a tool printed and how it exited
public struct PackageToolResult: Equatable, Sendable {

    /// The exit status
    public var status: Int32

    /// Standard output
    public var output: Data

    /// Standard error, as text
    public var errorText: String

    /// @brief A result.
    /// @param status The exit status
    /// @param output Standard output
    /// @param errorText Standard error
    /// @return The result
    public init(status: Int32, output: Data, errorText: String) {
        self.status = status
        self.output = output
        self.errorText = errorText
    }
}

/// @brief Runs package managers' command line tools
public protocol PackageToolRunner: AnyObject {

    /// @brief Finds a tool.
    /// @param tool Its name ("swift")
    /// @return Its path, or nil if it isn't installed
    func find(_ tool: String) -> URL?

    /// @brief Runs a tool and waits for it.
    /// @param tool Its name
    /// @param arguments Its arguments
    /// @param folder The folder it runs in
    /// @return What it printed and how it exited
    /// @throws PackageError.toolMissing or .timedOut
    func run(_ tool: String, arguments: [String], in folder: URL) throws -> PackageToolResult
}

// MARK: - JSON Helpers

/// @brief Reading loosely typed JSON, as the tools print it
public enum PackageJSON: Sendable {

    /// @brief Parses a JSON object.
    /// @param data The JSON
    /// @param name What it is, for the error
    /// @return The object
    /// @throws PackageError.unreadable if it isn't one
    public static func object(_ data: Data, name: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PackageError.unreadable(name)
        }
        return object
    }

    /// @brief Reads a file holding a JSON object.
    /// @param url The file
    /// @return The object, or nil if the file doesn't exist
    /// @throws PackageError.unreadable if it isn't JSON
    public static func object(at url: URL) throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try object(data, name: url.lastPathComponent)
    }
}

// MARK: - Paths

extension URL {

    /// @brief A path as the navigator shows it beside a dependency:
    /// relative to a folder when below or beside it (../Kit), else
    /// absolute.
    /// @param folder The folder, usually the manifest's
    /// @return The path
    public func packageDisplayPath(relativeTo folder: URL) -> String {
        let target = standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var common = 0
        while common < target.count, common < base.count, target[common] == base[common] {
            common += 1
        }
        // Only the root in common: absolute reads better
        guard common > 1 else { return path }
        let ups = Array(repeating: "..", count: base.count - common)
        let rest = Array(target[common...])
        let parts = ups + rest
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}
