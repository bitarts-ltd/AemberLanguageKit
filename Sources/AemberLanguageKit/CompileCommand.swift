/**
    @file CompileCommand.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Data model for a single compile command in the compilation database.
    @details
    Represents a single entry in compile_commands.json, containing the
    directory, command line, and source file for a compilation unit.
    Conforms to Codable for JSON serialization; unknown keys are ignored
    when decoding, and absent optional fields are left out when encoding.
*/

import Foundation

/// @brief A single compile command entry for compile_commands.json.
/// @details
/// This structure represents one compilation unit in the JSON
/// compilation database format used by clangd and other tools. Each
/// entry describes how to compile a single source file. Supports both
/// the "command" and "arguments" forms of the compile_commands.json
/// specification.
public struct CompileCommand: Codable, Sendable {
    /// The working directory of the compilation.
    public let directory: String

    /// The full compile command as it would be executed (optional if arguments
    /// is present).
    public let command: String?

    /// The source file being compiled (relative or absolute path).
    public let file: String

    /// The compile command as a list of strings (optional if command is
    /// present).
    public let arguments: [String]?

    /// The name of the output file (optional).
    public let output: String?

    /// @brief Create a new compile command.
    /// @param directory Working directory where compilation occurs
    /// @param command Full command line for compilation (optional if arguments
    /// is provided)
    /// @param file Source file path
    /// @param arguments Command as array of arguments (optional if command is
    /// provided)
    /// @param output Output file name (optional)
    public init(
        directory: String,
        command: String? = nil,
        file: String,
        arguments: [String]? = nil,
        output: String? = nil
    ) {
        self.directory = directory
        self.command = command
        self.file = file
        self.arguments = arguments
        self.output = output
    }
}
