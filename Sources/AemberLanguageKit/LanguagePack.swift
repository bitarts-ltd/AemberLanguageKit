/**
    @file LanguagePack.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief
    The protocol a language pack implements, and what Aember gives it.
    @details
    A pack contributes languages, language servers, build systems and
    package managers; everything but its manifest is optional. Aember
    asks for the contributions when it enables the pack and drops them
    when it disables it, so a pack returns the same contributions every
    time and keeps no state the next enable needs.

    Every contribution has an identifier that is stable across versions
    (a ContributionID: the pack, the kind, the contribution's own id),
    and Aember looks contributions up for a scope. Today the scope is
    always .global, the packs enabled app-wide; a project may later
    turn a pack, or one contribution, off for itself, and its settings
    are kept per scope (LanguagePackContext.settings(for:)) for the
    same reason.
*/

import Foundation

/// @brief Who made a pack, and what it is.
public struct LanguagePackManifest: Sendable {

    /// Lowercase and stable across versions ("swift", "c-family"); the
    /// same as the Info.plist's AemberPackID
    public var id: String

    /// The name shown in Settings
    public var name: LocalizedText

    /// The pack's version
    public var version: LanguagePackVersion

    /// One line about it
    public var summary: LocalizedText

    /// Who made it
    public var author: String

    /// Where to read about it
    public var homepage: URL?

    /// @brief A manifest.
    /// @param id The pack's identifier
    /// @param name Its name
    /// @param version Its version
    /// @param summary One line about it
    /// @param author Who made it
    /// @param homepage Where to read about it
    /// @return The manifest
    public init(id: String, name: LocalizedText, version: LanguagePackVersion, summary: LocalizedText = "", author: String, homepage: URL? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.author = author
        self.homepage = homepage
    }
}

/// @brief What a pack's contributions apply to.
public enum LanguagePackScope: Hashable, Sendable {

    /// Every project: the packs enabled app-wide
    case global

    /// One project, by its root folder
    case project(URL)
}

/// @brief What kind of thing a pack contributes.
public enum ContributionKind: String, Hashable, Sendable, Codable, CaseIterable {
    case language
    case languageServer
    case buildSystem
    case packageBackend
}

/// @brief One contribution of one pack, stable across versions, so a
/// setting can name it.
public struct ContributionID: Hashable, Sendable, Codable, CustomStringConvertible {

    /// The pack's identifier
    public var pack: String

    /// What it is
    public var kind: ContributionKind

    /// Its own identifier within the pack and kind ("xcode", "clangd")
    public var id: String

    /// @brief A contribution's identifier.
    /// @param pack The pack's identifier
    /// @param kind What it is
    /// @param id Its own identifier
    /// @return The identifier
    public init(pack: String, kind: ContributionKind, id: String) {
        self.pack = pack
        self.kind = kind
        self.id = id
    }

    /// @brief "pack/kind/id".
    /// @return The string
    public var description: String {
        "\(pack)/\(kind.rawValue)/\(id)"
    }
}

/// @brief A pack's settings in one scope, kept by Aember.
public protocol LanguagePackSettings: AnyObject, Sendable {

    /// @brief A setting's value.
    /// @param key The setting
    /// @return Its value, a property list type, or nil
    func value(forKey key: String) -> Any?

    /// @brief Changes a setting.
    /// @param value A property list value, or nil to remove it
    /// @param key The setting
    /// @return None
    func setValue(_ value: Any?, forKey key: String)
}

/// @brief What Aember gives a pack when it enables it.
public protocol LanguagePackContext: AnyObject, Sendable {

    /// Aember's version
    var appVersion: String { get }

    /// The SDK version Aember was built with
    var apiVersion: LanguagePackVersion { get }

    /// @brief Writes a line to Aember's log, under the pack's name.
    /// @param message The line
    /// @return None
    func log(_ message: String)

    /// @brief The pack's settings in a scope.
    /// @param scope The scope; .global for app-wide settings
    /// @return The settings
    func settings(for scope: LanguagePackScope) -> any LanguagePackSettings

    /// @brief Finds a command where Aember finds builds' and servers'
    /// commands: the usual folders, the given ones, then the login
    /// shell's PATH (an app opened from the Finder has a bare PATH).
    /// @param name The command
    /// @param directories More folders to look in, after the usual ones
    /// @return Its path, or nil
    func findExecutable(named name: String, also directories: [String]) -> URL?
}

/// @brief A language pack.
public protocol LanguagePack: AnyObject {

    /// Who made it and what it is
    var manifest: LanguagePackManifest { get }

    /// The languages it defines
    var languages: [LanguageDefinition] { get }

    /// The language servers it runs
    var languageServers: [LanguageServerDefinition] { get }

    /// The build systems it detects
    var buildSystems: [BuildSystemProvider] { get }

    /// The package managers it reads and changes
    var packageBackends: [PackageBackend.Type] { get }

    /// @brief Called when Aember enables the pack, before it asks for
    /// its contributions.
    /// @param context What Aember gives the pack
    /// @return None
    func activate(context: any LanguagePackContext)

    /// @brief Called when Aember disables the pack. Its code stays
    /// loaded until Aember quits.
    /// @return None
    func deactivate()
}

extension LanguagePack {

    /// No languages
    public var languages: [LanguageDefinition] { [] }

    /// No servers
    public var languageServers: [LanguageServerDefinition] { [] }

    /// No build systems
    public var buildSystems: [BuildSystemProvider] { [] }

    /// No package managers
    public var packageBackends: [PackageBackend.Type] { [] }

    /// @brief Nothing to do.
    /// @param context What Aember gives the pack
    /// @return None
    public func activate(context: any LanguagePackContext) {
    }

    /// @brief Nothing to do.
    /// @return None
    public func deactivate() {
    }
}
