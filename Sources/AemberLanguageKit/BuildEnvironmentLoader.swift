/**
    @file BuildEnvironmentLoader.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Loads a project's build environment from its .aember folder.
    @details
    Provides the environment for the build system's processes: builds,
    tests and the compilation database generators, so a Makefile or
    CMakeLists can be configured through defines in it. Variables are
    KEY=VALUE lines, with comments and quoted values.

    Three layers, each over the one before: the app's own environment;
    the project's shared variables, .aember/{identifier}-env; and the
    project's active named environment (Debug, Release, Sanitizers...),
    .aember/{identifier}-env.{name}. The Build Environments dialog edits
    them. The active environment's name is in .aember/active-env, which
    is the user's own (.aember is kept out of git by default); with
    none, or one whose file is gone, only the shared variables apply.
*/

import Foundation

/// @brief Loads environment variables from .aember env files for
/// build system processes.
public enum BuildEnvironmentLoader {

    /// @brief The file naming the active environment
    public static let activeFileName = "active-env"

    /// @brief Load environment for a build system process.
    /// @detail
    /// Starts with the current process environment, merges in the
    /// project's shared variables, then its active environment's.
    /// @param projectURL The project root directory
    /// @param identifier The build system identifier (e.g. "cmake")
    /// @return Merged environment dictionary
    public static func loadEnvironment(
        projectURL: URL,
        identifier: String
    ) -> [String: String] {
        return loadEnvironment(
            projectURL: projectURL,
            identifier: identifier,
            environment: activeEnvironment(
                projectURL: projectURL,
                identifier: identifier
            )
        )
    }

    /// @brief Load environment with a given named environment.
    /// @param projectURL The project root directory
    /// @param identifier The build system identifier (e.g. "cmake")
    /// @param environment The named environment laid over the shared
    /// variables, or nil for the shared variables only
    /// @return Merged environment dictionary
    public static func loadEnvironment(
        projectURL: URL,
        identifier: String,
        environment name: String?
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(
            variables(projectURL: projectURL, identifier: identifier)
        ) { _, new in new }
        if let name {
            environment.merge(variables(
                projectURL: projectURL, identifier: identifier, environment: name
            )) { _, new in new }
        }
        return environment
    }

    /// @brief The variables in one file.
    /// @param projectURL The project root directory
    /// @param identifier The build system identifier
    /// @param environment A named environment, or nil for the shared
    /// variables
    /// @return The variables, none when there is no file
    public static func variables(
        projectURL: URL,
        identifier: String,
        environment: String? = nil
    ) -> [String: String] {
        let url = environmentFileURL(
            projectURL: projectURL,
            identifier: identifier,
            environment: environment
        )
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }
        return parse(content)
    }

    /// @brief Parses KEY=VALUE lines.
    /// @detail
    /// Lines starting with # are comments, and values may be single-
    /// or double-quoted.
    /// @param content The text
    /// @return The variables
    public static func parse(_ content: String) -> [String: String] {
        var variables: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(
                in: .whitespaces
            )
            // Skip comments and empty lines
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#") else {
                continue
            }
            // Parse KEY=VALUE format
            if let equalIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<equalIndex])
                var value = String(
                    trimmed[trimmed.index(after: equalIndex)...]
                )
                // Strip surrounding quotes (shell-style)
                if (value.hasPrefix("\"")
                    && value.hasSuffix("\""))
                    || (value.hasPrefix("'")
                        && value.hasSuffix("'")) {
                    value = String(
                        value.dropFirst().dropLast()
                    )
                }
                variables[key] = value
            }
        }
        return variables
    }

    // MARK: - Files

    /// @brief The file of the shared variables, or of an environment.
    /// @param projectURL The project root directory
    /// @param identifier The build system identifier
    /// @param environment A named environment, or nil for the shared
    /// variables
    /// @return .aember/{identifier}-env or .aember/{identifier}-env.{name}
    public static func environmentFileURL(
        projectURL: URL,
        identifier: String,
        environment: String? = nil
    ) -> URL {
        var name = "\(identifier)-env"
        if let environment {
            name += "." + environment
        }
        return projectURL
            .appendingPathComponent(".aember")
            .appendingPathComponent(name)
    }

    // MARK: - Named Environments

    /// @brief The project's named environments.
    /// @param projectURL The project root directory
    /// @param identifier The build system identifier
    /// @return Their names, sorted
    public static func environments(
        projectURL: URL,
        identifier: String
    ) -> [String] {
        let folder = projectURL.appendingPathComponent(".aember")
        let prefix = "\(identifier)-env."
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: folder.path
        )) ?? []
        return names
            .filter { $0.hasPrefix(prefix) && $0.count > prefix.count }
            .map { String($0.dropFirst(prefix.count)) }
            .filter(isValidEnvironmentName)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// @brief The project's active environment.
    /// @param projectURL The project root directory
    /// @param identifier The build system identifier
    /// @return Its name, or nil when none is active or its file is gone
    public static func activeEnvironment(
        projectURL: URL,
        identifier: String
    ) -> String? {
        let url = projectURL
            .appendingPathComponent(".aember")
            .appendingPathComponent(activeFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard environments(projectURL: projectURL, identifier: identifier)
            .contains(name)
        else {
            return nil
        }
        return name
    }

    /// @brief Makes an environment the project's active one, or none.
    /// @param name The environment's name, or nil for the shared
    /// variables only
    /// @param projectURL The project root directory
    /// @return Nothing
    /// @throws When .aember can't be written
    public static func setActiveEnvironment(
        _ name: String?,
        projectURL: URL
    ) throws {
        let folder = projectURL.appendingPathComponent(".aember")
        let url = folder.appendingPathComponent(activeFileName)
        guard let name else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        try (name + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// @brief Whether a name can name an environment: not empty, and
    /// letters, digits, "-", "_" and "." only (not first), so it makes
    /// a file name.
    public static func isValidEnvironmentName(_ name: String) -> Bool {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_."))
        return !name.isEmpty && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy(allowed.contains)
    }
}
