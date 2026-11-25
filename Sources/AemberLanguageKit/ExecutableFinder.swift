/**
    @file ExecutableFinder.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Utility for finding executables in common locations.
    @details
    macOS GUI applications don't inherit the user's shell PATH, which causes
    issues when trying to launch build tools installed via Homebrew, MacPorts,
    or other package managers. This utility searches common installation
    locations and a tool's own (such as ~/.cargo/bin), then the PATH a
    login shell sets up, and builds the PATH a build's processes get.
    Build tools and language servers are both found with it.
*/

import Foundation

/// @brief Utility for finding executables in common locations.
public struct ExecutableFinder {

    /// @brief Common installation directories for build tools on macOS.
    /// @detail
    /// Ordered by likelihood: Homebrew locations first (most common),
    /// then system paths, then MacPorts, then user-local installations.
    private static let commonPaths = [
        // Homebrew (Apple Silicon)
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",

        // Homebrew (Intel)
        "/usr/local/bin",
        "/usr/local/sbin",

        // System paths
        "/usr/bin",
        "/bin",

        // MacPorts
        "/opt/local/bin",
        "/opt/local/sbin",

        // User-local installations
        "~/.local/bin",

        // CMake.app bundle (if installed as GUI app)
        "/Applications/CMake.app/Contents/bin",
    ]

    /// @brief The most seconds a login shell gets to report its PATH.
    private static let shellTimeout: TimeInterval = 10

    /// @brief Find the full path to an executable.
    /// @detail
    /// Searches for the executable in common installation directories,
    /// then in the tool's own. If not found, searches the user's
    /// shell's PATH. Blocks until the shell exits, so call it off the
    /// main thread.
    /// @param name The executable name (e.g., "cmake", "ninja")
    /// @param extraDirectories Directories the tool may also be
    /// installed in, searched after the common ones (~ is expanded)
    /// @return Full path to the executable, or nil if not found
    public static func findExecutable(
        named name: String,
        also extraDirectories: [String] = []
    ) -> String? {
        // Expand ~ in paths
        let expandedPaths = (commonPaths + extraDirectories).map { path in
            (path as NSString).expandingTildeInPath
        }

        // Search common paths first
        if let path = findExecutable(named: name, in: expandedPaths) {
            return path
        }

        // If not found in common paths, try reading shell PATH
        if let shellPaths = shellPATH {
            return findExecutable(named: name, in: shellPaths)
        }

        return nil
    }

    /// @brief Find an executable in a list of directories.
    /// @detail
    /// Returns the first `directory/name` that is an executable file,
    /// searching the directories in order. Directories are skipped even
    /// though `isExecutableFile` reports searchable directories as
    /// executable.
    /// @param name The executable name (e.g., "cmake", "ninja")
    /// @param directories Directories to search, in priority order
    /// @return Full path to the executable, or nil if not found
    public static func findExecutable(
        named name: String,
        in directories: [String]
    ) -> String? {
        let fileManager = FileManager.default

        for directory in directories {
            let executablePath = (directory as NSString)
                .appendingPathComponent(name)
            var isDirectory: ObjCBool = false

            if fileManager.fileExists(
                atPath: executablePath,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: executablePath) {
                return executablePath
            }
        }

        return nil
    }

    /// @brief A PATH that also searches the common directories.
    /// @detail
    /// A GUI app's PATH is /usr/bin:/bin:/usr/sbin:/sbin, so tools a
    /// build runs (node for npx, cc for make) need Homebrew's and the
    /// others' directories added, after the ones already there.
    /// @param current The PATH to extend, or nil
    /// @param first Directories to search before all others, such as
    /// the directory of the tool being run
    /// @return The colon-separated PATH, without repeats
    public static func augmentedPATH(_ current: String?, first: [String] = []) -> String {
        let common = commonPaths.map { ($0 as NSString).expandingTildeInPath }
        var seen = Set<String>()
        var directories: [String] = []
        for directory in first + parsePATH(current ?? "") + common
        where seen.insert(directory).inserted {
            directories.append(directory)
        }
        return directories.joined(separator: ":")
    }

    /// @brief Split a PATH-style string into directories.
    /// @param pathString Colon-separated directory list
    /// @return Non-empty directory entries, in order
    public static func parsePATH(_ pathString: String) -> [String] {
        return pathString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ":")
            .filter { !$0.isEmpty }
    }

    /// @brief The user's shell's PATH, read the first time it's needed.
    /// @detail
    /// Starting the user's shell runs their startup files, so it's
    /// done once per launch.
    private static let shellPATH: [String]? = readShellPATH()

    /// @brief Marks the line holding the PATH in a shell's output.
    private static let pathMarker = "__AEMBER_PATH__"

    /// @brief Read PATH from the user's shell, or else from sh.
    /// @detail
    /// The user's shell runs as a login and interactive shell, so
    /// .zprofile, .zshrc and their like count. /bin/sh -l reads only
    /// /etc/profile (path_helper's /etc/paths and /etc/paths.d) and
    /// ~/.profile.
    /// @return Array of directory paths from shell PATH, or nil if failed
    private static func readShellPATH() -> [String]? {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell,
           let paths = readPATH(
               shell: String(cString: shell),
               arguments: ["-l", "-i"]
           ) {
            return paths
        }
        return readPATH(shell: "/bin/sh", arguments: ["-l"])
    }

    /// @brief Find the PATH a shell printed.
    /// @detail
    /// Startup files may print anything, so the PATH is the last line
    /// that starts with the marker.
    /// @param output The shell's standard output
    /// @return The PATH's directories, or nil if no line has the marker
    public static func parseShellOutput(_ output: String) -> [String]? {
        guard let line = output.components(separatedBy: "\n")
            .last(where: { $0.hasPrefix(pathMarker) }) else {
            return nil
        }
        return parsePATH(String(line.dropFirst(pathMarker.count)))
    }

    /// @brief Read PATH from a shell.
    /// @detail
    /// Both pipes are drained before waiting, so a chatty startup file
    /// can't block it; stdin is empty and the shell gets `shellTimeout`
    /// seconds, so neither can one that waits for input or never
    /// finishes.
    /// @param shell The shell's path
    /// @param arguments Its options, before the command
    /// @return The PATH's directories, or nil if failed
    public static func readPATH(shell: String, arguments: [String]) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments + [
            "-c",
            "printf '\\n\(pathMarker)%s\\n' \"$PATH\""
        ]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        guard let data = process.readToEndAndWait(
            output: output,
            error: error,
            timeout: shellTimeout
        )?.output else {
            return nil
        }
        return String(data: data, encoding: .utf8).flatMap(parseShellOutput)
    }

}
