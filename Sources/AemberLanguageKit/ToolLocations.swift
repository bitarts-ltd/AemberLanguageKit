/**
    @file ToolLocations.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Where command line tools install themselves, beyond the usual
    folders.
    @details
    An app opened from the Finder doesn't get the shell's PATH, so a
    pack whose server or tool installs somewhere unusual names that
    folder in its LanguageServerDefinition's searchDirectories (or
    passes it to LanguagePackContext.findExecutable). These are the
    folders Aember's own servers use.
*/

import Foundation

/// @brief Folders tools install themselves in
public enum ToolLocations {

    /// @brief Where `npm install -g` puts a package's command.
    /// @details
    /// Beyond Homebrew's and /usr/local, which Aember always searches:
    /// ~/.npm-global, Volta's, and each nvm Node version's, newest
    /// first.
    /// @return Folders to try, in order
    public static func npmGlobalDirectories() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = [
            home.appendingPathComponent(".npm-global/bin").path,
            home.appendingPathComponent(".volta/bin").path,
        ]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []
        for version in versions.sorted(by: >) {
            directories.append(nvm.appendingPathComponent(version).appendingPathComponent("bin").path)
        }
        return directories
    }

    /// Where Cargo installs commands (rustup's rust-analyzer too)
    public static let cargoDirectory = "~/.cargo/bin"
}
