/**
    @file BuildSystem.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief A project's build system, as a pack defines it, and the commands it
    gives.
    @details
    A BuildSystem is what one build system found in one project: its
    identifier ("swiftpm", "cmake", ...), which names the project's
    environment files, the files that mark it (`buildFiles`), the
    commands that build and test the project, and what the language
    servers need from it (a compilation database, a buildServer.json,
    or nothing).

    A BuildSystemProvider detects one kind of build system in a project
    root. Aember asks the providers in priority order, lowest first, and
    the project gets the first that detects it, so a package with an
    Xcode project beside it is SwiftPM (priority 100) rather than Xcode
    (500). A pack's provider with the identifier of one Aember has
    takes its place.

    Commands come only from the build system or the project's
    .aember/build.json, never from an agent: an agent picks build or
    test and at most a filter, which Aember checks before a system sees
    it (only given for test, neither starting with "-" nor spanning
    lines).
*/

import Foundation

/// @brief What a run does: build the project, run its tests, or change
/// its packages
@frozen
public enum BuildAction: String, Hashable, Sendable {
    case build
    case test
    /// A package manager's change, with its own command
    case packages
}

/// @brief One process a command runs
public struct BuildStep: Equatable, Sendable {

    /// A name looked up on PATH, a path relative to the project, or an
    /// absolute path
    public var executable: String

    /// Its arguments
    public var arguments: [String]

    /// @brief A step.
    /// @param executable The program
    /// @param arguments Its arguments
    /// @return The step
    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// @brief The step as a shell would show it
    public var displayString: String {
        ([executable] + arguments).map(BuildCommand.quoted).joined(separator: " ")
    }
}

/// @brief What runs to build or test a project
public struct BuildCommand: Equatable, Sendable {

    /// The processes, run in order until one fails
    public var steps: [BuildStep]

    /// Names the .aember/<identifier>-env file the environment comes from
    public var environmentIdentifier: String

    /// The Xcode result bundle the command writes, read afterwards
    public var resultBundle: URL?

    /// The JUnit report the command writes, read afterwards
    public var junitReport: URL?

    /// @brief A command.
    /// @param steps The processes
    /// @param environmentIdentifier Names the environment file
    /// @param resultBundle The Xcode result bundle it writes
    /// @param junitReport The JUnit report it writes
    /// @return The command
    public init(steps: [BuildStep], environmentIdentifier: String, resultBundle: URL? = nil, junitReport: URL? = nil) {
        self.steps = steps
        self.environmentIdentifier = environmentIdentifier
        self.resultBundle = resultBundle
        self.junitReport = junitReport
    }

    /// @brief The command as a shell would show it
    public var displayString: String {
        steps.map(\.displayString).joined(separator: " && ")
    }

    /// @brief An argument quoted for display, when it needs quoting.
    /// @param argument The argument
    /// @return It, or it in single quotes
    public static func quoted(_ argument: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:,+@%"))
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(plain.contains) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// @brief A project's .aember/build.json, which the user writes and
/// which is meant to be committed with the project.
/// @details
/// Every key is optional. build and test replace the build system's
/// command; testFilter is the arguments a test filter adds to a test
/// command from build.json, with {filter} replaced. scheme,
/// destination and configuration are xcodebuild's; buildDirectory is
/// CMake's and Ninja's.
public struct BuildProjectConfig: Decodable, Equatable, Sendable {
    public var build: [String]?
    public var test: [String]?
    public var testFilter: [String]?
    public var scheme: String?
    public var destination: String?
    public var configuration: String?
    public var buildDirectory: String?

    /// @brief Settings; every one is optional.
    /// @return The settings
    public init(build: [String]? = nil, test: [String]? = nil, testFilter: [String]? = nil, scheme: String? = nil, destination: String? = nil, configuration: String? = nil, buildDirectory: String? = nil) {
        self.build = build
        self.test = test
        self.testFilter = testFilter
        self.scheme = scheme
        self.destination = destination
        self.configuration = configuration
        self.buildDirectory = buildDirectory
    }

    /// @brief The file's place in a project.
    /// @param projectRoot The project folder
    /// @return .aember/build.json in it
    public static func url(in projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".aember").appendingPathComponent("build.json")
    }

    /// @brief Reads a project's build.json.
    /// @param projectRoot The project folder
    /// @return The settings, or nil when there is no file
    /// @throws BuildCommandError.invalidConfig when it can't be read
    public static func load(from projectRoot: URL) throws -> BuildProjectConfig? {
        let url = url(in: projectRoot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(BuildProjectConfig.self, from: data)
        } catch {
            throw BuildCommandError.invalidConfig(error.localizedDescription)
        }
    }
}

/// @brief Why a project has no command to run
@frozen
public enum BuildCommandError: Error, Equatable, Sendable {

    /// The build system has no such command, and why, for the user
    case noCommand(String)

    /// build.json can't be read: the reason
    case invalidConfig(String)

    /// The command takes no filter, or the filter isn't allowed, and
    /// why, for the user
    case badFilter(String)

    /// The build system gives no command for the action, and build.json
    /// none either: the system's name. Aember's message asks for
    /// build.json's key.
    case unsupported(action: BuildAction, system: String)
}

/// @brief What a build system gives the language servers
@frozen
public enum CompilationDatabaseOutput: Equatable, Sendable {
    /// A compile_commands.json written for clangd, which is normalized
    /// and cached by the build file's date
    case generated(URL)
    /// A buildServer.json sourcekit-lsp reads, used as it is
    case buildServer(URL)
    /// Nothing written: the file or folder the language server reads
    case native(URL)
}

/// @brief What Aember hands a build system's commands and compilation
/// database. Aember's own systems find their tools in it; a pack's
/// asks it for the build tools it runs, which tests replace.
public protocol BuildSystemContext {

    /// @brief A build tool to run in place of the one found on the
    /// PATH: tests give fake ones.
    /// @param name The tool's name ("cmake", "make")
    /// @return Its path, or nil to find it as usual
    func toolPath(_ name: String) -> String?
}

extension BuildSystemContext {

    /// @brief By default every tool is found as usual.
    /// @param name The tool's name
    /// @return nil
    public func toolPath(_ name: String) -> String? {
        nil
    }
}

/// @brief One build system, as detected in one project
public protocol BuildSystem: Equatable, Sendable {

    /// Lowercase name for configuration files ("cmake", "swiftpm");
    /// names the project's .aember/<identifier>-env files
    var identifier: String { get }

    /// The name shown to the user
    var displayName: String { get }

    /// @brief The files that mark this build system, preferred first.
    /// @details
    /// Paths relative to the project root. The compilation database's
    /// cache and watcher follow the first that exists, so it should be
    /// the file that changes when the build does.
    var buildFiles: [String] { get }

    /// @brief The command for an action, when build.json gives none.
    /// @details
    /// The filter has been checked: it is only given for test, and
    /// neither starts with "-" nor spans lines. A system without a
    /// command for the action throws BuildCommandError.unsupported or
    /// .noCommand, and one whose command takes no filter, .badFilter.
    /// @param action Build or test
    /// @param projectRoot The project folder
    /// @param config The project's build.json, if any, for its settings
    /// @param filter The tests to run, for test; nil for all
    /// @param outputDirectory Where reports the command writes go
    /// @param context What Aember hands the system
    /// @return The command
    /// @throws BuildCommandError when there is none
    func command(for action: BuildAction, in projectRoot: URL, config: BuildProjectConfig?, filter: String?, outputDirectory: URL, context: any BuildSystemContext) throws -> BuildCommand

    /// @brief What the language servers need from this build system.
    /// @details
    /// Runs off the main thread. The default needs nothing: the
    /// language server reads the project's own files.
    /// @param projectURL The project folder
    /// @param context What Aember hands the system
    /// @param onOutput Receives progress lines
    /// @return What was written, or the folder when nothing was
    /// @throws When generation fails
    func compilationDatabase(for projectURL: URL, context: any BuildSystemContext, onOutput: ((String) -> Void)?) async throws -> CompilationDatabaseOutput
}

extension BuildSystem {

    /// @brief By default a system has no command: build.json must give
    /// one.
    /// @return Never
    /// @throws BuildCommandError.unsupported
    public func command(for action: BuildAction, in projectRoot: URL, config: BuildProjectConfig?, filter: String?, outputDirectory: URL, context: any BuildSystemContext) throws -> BuildCommand {
        throw BuildCommandError.unsupported(action: action, system: displayName)
    }

    /// @brief By default the language server reads the project itself.
    /// @return .native(projectURL)
    public func compilationDatabase(for projectURL: URL, context: any BuildSystemContext, onOutput: ((String) -> Void)?) async throws -> CompilationDatabaseOutput {
        .native(projectURL)
    }

    /// @brief The first of `buildFiles` that exists in a project.
    /// @param projectURL The project root
    /// @return The file's URL, nil when none exists
    public func buildFileURL(in projectURL: URL) -> URL? {
        buildFiles.map { projectURL.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// @brief Whether another build system is the same as this one.
    /// @param other The other system
    /// @return True when it is the same kind, with the same settings
    public func isSame(as other: (any BuildSystem)?) -> Bool {
        (other as? Self) == self
    }

    /// @brief A command of one step.
    /// @param executable The program
    /// @param arguments Its arguments
    /// @return The command, with this system's environment
    public func single(_ executable: String, _ arguments: [String]) -> BuildCommand {
        BuildCommand(steps: [BuildStep(executable: executable, arguments: arguments)], environmentIdentifier: identifier)
    }
}

/// @brief A build system that knows how to find itself
public protocol DetectableBuildSystem: BuildSystem {

    /// The identifier every value of the type has
    static var identifier: String { get }

    /// @brief Detects the system in a project root.
    /// @param projectRoot The project root
    /// @return The system, nil when the root has none
    static func detect(in projectRoot: URL) -> Self?
}

extension DetectableBuildSystem {

    /// The type's identifier
    public var identifier: String {
        Self.identifier
    }
}

/// @brief Detects one kind of build system in a project root
public struct BuildSystemProvider: Sendable {

    /// The identifier of the systems it detects
    public let identifier: String

    /// Lower is asked first. Aember's own: SwiftPM 100, Cargo 200,
    /// CMake 300, Ninja 400, Xcode 500, Make 600, TypeScript 700,
    /// Python 800, PHP 900.
    public let priority: Int

    /// Detects the system in a project root, nil when it isn't there
    public let detect: @Sendable (URL) -> (any BuildSystem)?

    /// @brief A provider from a closure.
    /// @param identifier The identifier of the systems it detects
    /// @param priority Lower is asked first
    /// @param detect Detects the system in a project root
    /// @return The provider
    public init(identifier: String, priority: Int, detect: @escaping @Sendable (URL) -> (any BuildSystem)?) {
        self.identifier = identifier
        self.priority = priority
        self.detect = detect
    }

    /// @brief A provider for a system that detects itself.
    /// @param type The system's type
    /// @param priority Lower is asked first
    /// @return The provider
    public init<System: DetectableBuildSystem>(_ type: System.Type, priority: Int) {
        self.identifier = System.identifier
        self.priority = priority
        self.detect = { System.detect(in: $0) }
    }
}
