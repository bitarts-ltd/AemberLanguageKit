/**
    @file CompilationDatabaseError.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Error types for compilation database generation.
    @details
    The errors shared by the manager and the generators: a project with
    no build system to generate from, a build tool missing, no compile
    commands found, and a database that can't be written; and make
    failing or printing unreadable output. The CMake, Ninja and Xcode
    generators have error types of their own for the rest.
*/

import Foundation

/// @brief Errors that can occur during compilation database generation.
@frozen
public enum CompilationDatabaseError: Error {
    /// The project has no build system a database can be generated
    /// from.
    case noMakefileFound

    /// make failed without printing a database.
    case makeExecutionFailed(status: Int32)

    /// make's output isn't UTF-8.
    case invalidOutput

    /// Failed to write compile_commands.json to disk.
    case writeError(Error)

    /// A build tool (cmake, ninja, make) wasn't found.
    case toolNotFound(String)

    /// The build tool's output had no compile commands in it.
    case noCompilationCommands
}
