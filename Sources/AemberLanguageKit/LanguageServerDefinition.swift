/**
    @file LanguageServerDefinition.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief
    A language server a pack runs for its languages.
    @details
    A LanguageServerDefinition names the server's command and arguments,
    the LSP languages it serves, and the hooks for servers that need
    more: finding the executable somewhere unusual (sourcekit-lsp
    through xcrun), refusing a version that can't serve LSP (tsc before
    7), arguments that depend on the project (clangd's compile commands
    folder), and preparing the project before it starts. Where several
    servers serve a language, Aember uses the first installed, in
    priority order. Languages that share a serverKey share one running
    server per project (clangd for C, C++ and Objective-C).
*/

import Foundation

/// @brief When Aember restarts a running server
public enum LanguageServerRestartTrigger: String, Hashable, Sendable, CaseIterable {

    /// The project's compilation database was written again
    case compilationDatabaseChanged

    /// A buildServer.json was written for the project
    case buildServerConfigured
}

/// @brief One language server.
public struct LanguageServerDefinition: Sendable {

    /// The server's name, unique across packs ("clangd")
    public var name: String

    /// The command: a name looked up on the PATH and in the usual
    /// folders, or a path
    public var executable: String

    /// The command's arguments
    public var arguments: [String]

    /// The LSP language IDs it serves ("c", "cpp", "objective-c")
    public var languages: [String]

    /// The name its languages share one server under, per project; nil
    /// gives each language its own
    public var serverKey: String?

    /// Lower runs first when several servers serve a language
    public var priority: Int

    /// Folders to look in after the usual ones ("~/.cargo/bin")
    public var searchDirectories: [String]

    /// Sent with initialize, as JSON
    public var initializationOptions: Data?

    /// What to install, shown when the server isn't found
    public var installGuidance: LocalizedText

    /// When a running server is restarted
    public var restartTriggers: Set<LanguageServerRestartTrigger>

    /// Finds the executable itself, before the usual search; nil when
    /// it isn't there
    public var locate: (@Sendable () -> URL?)?

    /// Whether an executable found can serve LSP (a version check);
    /// one it refuses counts as not installed
    public var accepts: (@Sendable (URL) -> Bool)?

    /// The arguments for a project, given the project's root and the
    /// configured arguments
    public var projectArguments: (@Sendable (URL, [String]) -> [String])?

    /// Runs before the server starts for a project
    public var prepare: (@Sendable (URL) -> Void)?

    /// @brief A server.
    /// @param name Its name
    /// @param executable Its command
    /// @param arguments The command's arguments
    /// @param languages The LSP language IDs it serves
    /// @param serverKey The key its languages share a server under
    /// @param priority Lower runs first among a language's servers
    /// @param searchDirectories More folders to look for it in
    /// @param initializationOptions Sent with initialize, as JSON
    /// @param installGuidance What to install when it isn't found
    /// @param restartTriggers When a running server restarts
    /// @param locate Finds the executable itself
    /// @param accepts Checks an executable found
    /// @param projectArguments The arguments for a project
    /// @param prepare Runs before it starts for a project
    /// @return The server
    public init(
        name: String,
        executable: String,
        arguments: [String] = [],
        languages: [String],
        serverKey: String? = nil,
        priority: Int = 0,
        searchDirectories: [String] = [],
        initializationOptions: Data? = nil,
        installGuidance: LocalizedText,
        restartTriggers: Set<LanguageServerRestartTrigger> = [],
        locate: (@Sendable () -> URL?)? = nil,
        accepts: (@Sendable (URL) -> Bool)? = nil,
        projectArguments: (@Sendable (URL, [String]) -> [String])? = nil,
        prepare: (@Sendable (URL) -> Void)? = nil
    ) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.languages = languages
        self.serverKey = serverKey
        self.priority = priority
        self.searchDirectories = searchDirectories
        self.initializationOptions = initializationOptions
        self.installGuidance = installGuidance
        self.restartTriggers = restartTriggers
        self.locate = locate
        self.accepts = accepts
        self.projectArguments = projectArguments
        self.prepare = prepare
    }

    /// @brief The arguments for a project.
    /// @param projectRoot The project's root
    /// @return The configured arguments, with the project's
    public func arguments(for projectRoot: URL) -> [String] {
        projectArguments?(projectRoot, arguments) ?? arguments
    }
}
