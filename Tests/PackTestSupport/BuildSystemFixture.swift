/**
    @file BuildSystemFixture.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Temporary project directories for build system tests.
    @details
    Creates a unique directory under the system temporary directory,
    offers helpers to populate it with files, directories, and fake
    executable shell scripts, and removes it when released. Build
    system tests use the fake scripts in place of cmake, ninja, make,
    and xcodebuild so they never depend on installed tools. The same as
    Aember's tests use.
*/

import Foundation

/// @brief A throwaway directory tree for build system tests.
public final class BuildSystemFixture {

    /// Root of the fixture directory tree
    public let root: URL

    /// @brief Create an empty, uniquely named temporary directory.
    /// @return Nothing
    public init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AemberTests-BuildSystem-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// @brief URL for a path relative to the fixture root.
    /// @param relativePath Path below the root
    /// @return Absolute URL inside the fixture
    public func url(_ relativePath: String) -> URL {
        return root.appendingPathComponent(relativePath)
    }

    /// @brief Write a file, creating parent directories as needed.
    /// @param relativePath Path below the root
    /// @param contents UTF-8 file contents
    /// @return URL of the written file
    @discardableResult
    public func write(_ relativePath: String, _ contents: String = "") throws
        -> URL {
        let fileURL = url(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// @brief Create a directory, including intermediate directories.
    /// @param relativePath Path below the root
    /// @return URL of the directory
    @discardableResult
    public func makeDirectory(_ relativePath: String) throws -> URL {
        let dirURL = url(relativePath)
        try FileManager.default.createDirectory(
            at: dirURL,
            withIntermediateDirectories: true
        )
        return dirURL
    }

    /// @brief Write an executable /bin/sh script.
    /// @param relativePath Path below the root
    /// @param body Script body, without the `#!/bin/sh` line
    /// @return URL of the script
    @discardableResult
    public func writeScript(_ relativePath: String, _ body: String) throws -> URL {
        let scriptURL = try write(relativePath, "#!/bin/sh\n" + body + "\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    /// @brief Read a fixture file as UTF-8 text.
    /// @param relativePath Path below the root
    /// @return File contents
    public func read(_ relativePath: String) throws -> String {
        return try String(contentsOf: url(relativePath), encoding: .utf8)
    }

    /// @brief Check whether a fixture path exists.
    /// @param relativePath Path below the root
    /// @return True if a file or directory exists at the path
    public func exists(_ relativePath: String) -> Bool {
        return FileManager.default.fileExists(atPath: url(relativePath).path)
    }
}

/// @brief Thread-safe collector for generator `onOutput` lines.
public final class OutputLines: @unchecked Sendable {

    /// @brief An empty collector.
    /// @return The collector
    public init() {}

    private let lock = NSLock()
    private var storage: [String] = []

    /// All lines received so far
    public var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// All lines joined with newlines
    public var text: String {
        return lines.joined(separator: "\n")
    }

    /// @brief Append a line; pass this as the `onOutput` callback.
    /// @param line The output line
    /// @return Nothing
    public func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }
}
