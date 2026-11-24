/**
    @file CompilationDatabaseFile.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Where the generators write the compilation database, and how.
    @details
    Every generator ends by writing .aember/compile_commands.json in the
    project: the CMake one copies what cmake wrote, Ninja's writes what
    `ninja -t compdb` printed, and Make's and Xcode's encode the commands
    they found. The file is written atomically, the .aember folder made
    when missing, and any failure is CompilationDatabaseError.writeError.
*/

import Foundation

/// @brief Writes a project's .aember/compile_commands.json.
public enum CompilationDatabaseFile {

    /// @brief The database's location in a project.
    /// @param projectURL The project root directory
    /// @return .aember/compile_commands.json in it
    public static func url(in projectURL: URL) -> URL {
        return projectURL
            .appendingPathComponent(".aember")
            .appendingPathComponent("compile_commands.json")
    }

    /// @brief Write a database's JSON to the project.
    /// @param data The JSON, as the generator has it
    /// @param projectURL The project root directory
    /// @return URL of the written file
    public static func write(_ data: Data, projectURL: URL) throws -> URL {
        let destination = url(in: projectURL)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        } catch {
            throw CompilationDatabaseError.writeError(error)
        }
        return destination
    }

    /// @brief Encode compile commands and write them to the project.
    /// @param commands The commands
    /// @param projectURL The project root directory
    /// @return URL of the written file
    public static func write(
        _ commands: [CompileCommand],
        projectURL: URL
    ) throws -> URL {
        let data: Data
        do {
            data = try JSONEncoder().encode(commands)
        } catch {
            throw CompilationDatabaseError.writeError(error)
        }
        return try write(data, projectURL: projectURL)
    }
}
