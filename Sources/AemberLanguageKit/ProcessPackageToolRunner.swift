/**
    @file ProcessPackageToolRunner.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Running package managers' tools as processes
    @details
    The runner Aember gives backends, and one a pack can make itself
    for what runs outside a backend (a search listing a repository's
    git tags). A tool is found as builds find it (ExecutableFinder,
    with the folders package managers install themselves in), run in
    the folder given with that tool's folder first on the PATH, and
    stopped after two minutes.
*/

import Foundation

/// @brief Runs tools as processes, found where builds find them.
public final class ProcessPackageToolRunner: PackageToolRunner {

    public init() {}

    /// The most seconds one command gets
    public static let timeout: TimeInterval = 120

    /// Where tools install themselves besides the common folders
    public static let toolDirectories = ["~/.cargo/bin", "~/.volta/bin", "~/.bun/bin"]

    public func find(_ tool: String) -> URL? {
        ExecutableFinder.findExecutable(named: tool, also: Self.toolDirectories)
            .map { URL(fileURLWithPath: $0) }
    }

    public func run(_ tool: String, arguments: [String], in folder: URL) throws -> PackageToolResult {
        guard let executable = find(tool) else {
            throw PackageError.toolMissing(tool)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ExecutableFinder.augmentedPATH(
            environment["PATH"],
            first: [executable.deletingLastPathComponent().path]
        )
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw PackageError.toolMissing(tool)
        }
        guard let data = process.readToEndAndWait(
            output: output,
            error: error,
            timeout: Self.timeout
        ) else {
            throw PackageError.timedOut(([tool] + arguments).joined(separator: " "))
        }
        return PackageToolResult(
            status: process.terminationStatus,
            output: data.output,
            errorText: String(decoding: data.error, as: UTF8.self)
        )
    }
}
