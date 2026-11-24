/**
    @file LanguagePackAPI.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief
    The SDK's version, the pack file's entry point and its Info.plist keys.
    @details
    A pack is a dynamic library, `<id>.aemberpack`, with its Info.plist
    embedded in its `__TEXT,__info_plist` section and one exported C
    function, `aember_language_pack`, which returns the pack, retained.
    Aember reads the plist without loading the code, so it can list a
    pack it refuses or that is disabled, and refuses a pack whose API
    major version it doesn't support before running any of it.
*/

import Foundation

/// @brief A version: major.minor.patch, compared numerically.
public struct LanguagePackVersion: Comparable, Hashable, Codable, Sendable, CustomStringConvertible {

    /// Breaking changes
    public var major: Int

    /// Additions
    public var minor: Int

    /// Fixes
    public var patch: Int

    /// @brief A version from its parts.
    /// @param major The major version
    /// @param minor The minor version
    /// @param patch The patch version
    /// @return The version
    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// @brief Parses "1", "1.2" or "1.2.3"; missing parts are 0.
    /// @param string The version string
    /// @return The version, or nil if a part isn't a number or there
    /// are more than three
    public init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else {
            return nil
        }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else {
                return nil
            }
            numbers.append(number)
        }
        while numbers.count < 3 {
            numbers.append(0)
        }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    /// @brief "major.minor.patch".
    /// @return The string
    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    /// @brief Orders by major, then minor, then patch.
    /// @param lhs One version
    /// @param rhs The other
    /// @return Whether lhs comes first
    public static func < (lhs: LanguagePackVersion, rhs: LanguagePackVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// @brief The SDK's version, the contract between Aember and packs.
/// @details
/// A pack says which API version it was built for (its Info.plist's
/// AemberPackAPIVersion). Aember loads a pack whose major version it
/// supports and whose minor version is no newer than its own. While
/// the major version is 0 the API may change between minor versions,
/// so a 0.x pack needs the same minor version.
public enum LanguagePackAPI {

    /// This SDK's version
    public static let version = LanguagePackVersion(0, 1)

    /// The C symbol a pack exports, returning the retained pack
    public static let entrySymbol = "aember_language_pack"

    /// The pack file's extension
    public static let fileExtension = "aemberpack"

    /// @brief Whether a pack built for an API version can be loaded by
    /// this SDK.
    /// @param packVersion The version the pack was built for
    /// @param hostVersion The SDK version Aember was built with
    /// @return True when it can
    public static func isCompatible(_ packVersion: LanguagePackVersion, with hostVersion: LanguagePackVersion = version) -> Bool {
        guard packVersion.major == hostVersion.major else {
            return false
        }
        if hostVersion.major == 0 {
            return packVersion.minor == hostVersion.minor
        }
        return packVersion.minor <= hostVersion.minor
    }

    /// @brief Hands a pack to Aember from the pack's entry point.
    /// @details
    /// A pack's one exported function:
    /// ```swift
    /// @_cdecl("aember_language_pack")
    /// public func aemberLanguagePack() -> UnsafeMutableRawPointer {
    ///     LanguagePackAPI.export(MyPack())
    /// }
    /// ```
    /// @param pack The pack
    /// @return The pack, retained, as Aember takes it
    public static func export(_ pack: any LanguagePack) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(pack as AnyObject).toOpaque()
    }

    /// @brief Takes the pack an entry point returned.
    /// @param pointer What the entry point returned
    /// @return The pack, or nil if the object isn't one
    public static func take(_ pointer: UnsafeMutableRawPointer) -> (any LanguagePack)? {
        Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue() as? any LanguagePack
    }
}

/// @brief The keys of a pack's embedded Info.plist.
public enum LanguagePackInfoKey {

    /// The pack's identifier, lowercase ("swift", "c-family")
    public static let identifier = "AemberPackID"

    /// The name shown in Settings
    public static let name = "AemberPackName"

    /// One line about the pack
    public static let summary = "AemberPackDescription"

    /// The API version it was built for ("0.1")
    public static let apiVersion = "AemberPackAPIVersion"

    /// The names of the languages it covers, for Settings
    public static let languages = "AemberPackLanguages"

    /// Who made it
    public static let author = "AemberPackAuthor"

    /// The pack's version, as bundles keep theirs
    public static let version = "CFBundleShortVersionString"

    /// The code signing identifier
    public static let bundleIdentifier = "CFBundleIdentifier"
}
