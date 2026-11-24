/**
    @file MakeCommandFilter.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Filters and analyzes Make commands to identify compilation.
    @details
    Examines expanded Make commands to determine if they are compilation
    commands (vs linking, archiving, etc.). Extracts compiler, flags,
    source files, and output files from compilation commands.
*/

import Foundation
import AemberLanguageKit

/// @brief Filters and extracts compilation commands.
class MakeCommandFilter {

    // Common compiler names
    private let compilerNames = [
        "gcc", "g++", "clang", "clang++", "cc", "c++",
        "arm-none-eabi-gcc", "arm-none-eabi-g++",
        "aarch64-linux-gnu-gcc", "aarch64-linux-gnu-g++",
        "swiftc"
    ]

    /// @brief Check if a command is a compilation command.
    /// @param command The fully expanded command string
    /// @return True if this is a compilation command (not linking/archiving)
    func isCompilationCommand(_ command: String) -> Bool {
        // Must contain a compiler name
        let hasCompiler = compilerNames.contains { compiler in
            command.contains(compiler)
        }

        guard hasCompiler else {
            return false
        }

        // Must have -c flag (compile, not link)
        guard command.contains(" -c ") || command.contains(" -c\t") else {
            return false
        }

        // Exclude linker commands (even if they mention a compiler)
        if command.contains(" -o ") && !command.contains(" -c ") {
            return false
        }

        // Exclude archive commands: ar or ranlib run as a command word,
        // possibly by path, not merely text ending in "ar" such as
        // -DFOO=bar or -Ivar
        let archivePattern = "(^|[\\s;&|/])(ar|ranlib)\\s"
        if command.range(
            of: archivePattern,
            options: .regularExpression
        ) != nil {
            return false
        }

        return true
    }

    /// @brief Extract compilation information from a command.
    /// @param command The fully expanded command string
    /// @param workingDirectory The directory where the command executes
    /// @return CompileCommand or nil if extraction fails
    func extractCompileCommand(
        from command: String,
        workingDirectory: String
    ) -> CompileCommand? {
        // Find source file (after -c flag)
        guard let sourceFile = extractSourceFile(from: command) else {
            return nil
        }

        // Find output file (after -o flag, if present)
        let outputFile = extractOutputFile(from: command)

        return CompileCommand(
            directory: workingDirectory,
            command: command,
            file: sourceFile,
            arguments: nil,
            output: outputFile
        )
    }

    // MARK: - Private Methods

    /// @brief Extract source file from compilation command.
    /// @detail
    /// Returns the first argument with a source file extension that is
    /// not the value of `-o`. The source may come anywhere on the line:
    /// make's built-in rules put it last, after `-o $@`.
    /// @param command The command string
    /// @return Source file path or nil
    private func extractSourceFile(from command: String) -> String? {
        let sourceExtensions: Set<String> = [
            "c", "cpp", "cc", "cxx", "c++", "m", "mm", "swift"
        ]
        let tokens = command
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        var index = 0

        while index < tokens.count {
            let token = tokens[index]

            // Skip the output file that follows -o
            if token == "-o" {
                index += 2
                continue
            }

            let fileExtension = (token as NSString).pathExtension.lowercased()
            if !token.hasPrefix("-"),
               sourceExtensions.contains(fileExtension) {
                return token
            }

            index += 1
        }

        return nil
    }

    /// @brief Extract output file from compilation command.
    /// @param command The command string
    /// @return Output file path or nil
    private func extractOutputFile(from command: String) -> String? {
        // Look for -o <output_file>
        let pattern = "-o\\s+(\\S+)"

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: command,
                range: NSRange(command.startIndex..., in: command)
              ) else {
            return nil
        }

        let nsString = command as NSString
        let outputFile = nsString.substring(with: match.range(at: 1))

        return outputFile
    }
}
