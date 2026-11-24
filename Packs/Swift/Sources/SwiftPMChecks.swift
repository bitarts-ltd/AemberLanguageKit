/**
    @file SwiftPMChecks.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Check for Updates for Swift packages
    @details
    SwiftPM lists each pinned package's versions, its git tags (`git
    ls-remote --tags`) or a registry package's releases, and compares
    them with the pin; a direct dependency's rule says which it allows.
    Swift has no audit.
*/

import Foundation
import AemberLanguageKit

// MARK: - SwiftPM

extension SwiftPMBackend {

    func check(graph: PackageGraph, http: PackageHTTP) async -> PackageCheckResult {
        let registries = SwiftRegistryConfiguration.load(for: folder)
        let runner = runner
        let found = await PackageCheckRunner.updates(of: graph.packages, in: graph) { package in
            try await Self.versions(of: package, registries: registries, http: http, runner: runner)
        }
        var result = PackageCheckResult(date: Date(), updates: found.updates)
        if let problem = PackageCheckRunner.failedProblem(found.failed, format: PackStrings.text("Couldn’t list the versions of %@.").localized) {
            result.problems.append(problem)
        }
        return result
    }

    /// @brief A pinned package's versions: a git package's tags, a
    /// registry package's releases.
    /// @param package The package
    /// @param registries The registries SwiftPM is set up with
    /// @param http The client
    /// @param runner Runs git
    /// @return The versions, or nil for a package pinned to a branch or
    /// revision, or on disk
    /// @throws When they couldn't be listed
    static func versions(
        of package: ResolvedPackage,
        registries: SwiftRegistryConfiguration,
        http: PackageHTTP,
        runner: PackageToolRunner
    ) async throws -> (versions: [String], latest: String?)? {
        guard package.version != nil else { return nil }
        switch package.source {
        case .git(let url):
            let tags = try await Task.detached { try GitTags.versions(of: url, runner: runner) }.value
            return (tags, nil)
        case .registry:
            let source = SwiftRegistrySearch(configuration: registries, http: http)
            let details = try await source.details(of: PackageSearchResult(name: package.id, location: package.id))
            return (details.versions, nil)
        case .path, .unknown:
            return nil
        }
    }
}
