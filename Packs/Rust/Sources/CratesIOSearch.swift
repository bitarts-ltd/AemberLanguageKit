/**
    @file CratesIOSearch.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Searching crates.io
    @details
    CratesIOSearch asks crates.io's API (/api/v1/crates?q=) for crates
    and /api/v1/crates/<name>/versions for one's versions, leaving out
    yanked ones. The parsers are static, for tests with saved answers.
*/

import Foundation
import AemberLanguageKit

/// @brief Searches crates.io
final class CratesIOSearch: PackageSearchSource {

    /// crates.io's API
    let baseURL: URL
    private let http: PackageHTTP

    /// @brief Creates the source.
    /// @param baseURL The API's address
    /// @param http The client
    init(baseURL: URL = URL(string: "https://crates.io/api/v1")!, http: PackageHTTP = PackageHTTP()) {
        self.baseURL = baseURL
        self.http = http
    }

    func search(_ text: String) async throws -> [PackageSearchResult] {
        let url = URL(string: baseURL.absoluteString + "/crates?per_page=25&q=" + text.packageURLComponent)!
        return try Self.parseSearch(await http.object(url), host: url.host ?? "")
    }

    func details(of result: PackageSearchResult) async throws -> PackageSearchDetails {
        let url = URL(string: baseURL.absoluteString + "/crates/" + result.location.packageURLComponent + "/versions")!
        let versions = try Self.parseVersions(await http.object(url), host: url.host ?? "")
        return PackageSearchDetails(summary: result.summary, versions: versions)
    }

    /// @brief Reads a search's answer.
    /// @param object The answer
    /// @param host The server, for the error
    /// @return The crates, in crates.io's order, with their newest
    /// stable version (else newest)
    /// @throws PackageSearchError.unreadable without a crates list
    static func parseSearch(_ object: [String: Any], host: String) throws -> [PackageSearchResult] {
        guard let crates = object["crates"] as? [[String: Any]] else {
            throw PackageSearchError.unreadable(host)
        }
        return crates.compactMap { crate in
            guard let name = crate["name"] as? String else { return nil }
            let latest = crate["max_stable_version"] as? String ?? crate["newest_version"] as? String ?? crate["max_version"] as? String
            return PackageSearchResult(
                name: name,
                location: name,
                summary: (crate["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                latestVersion: latest
            )
        }
    }

    /// @brief Reads a crate's versions.
    /// @param object The answer
    /// @param host The server, for the error
    /// @return The versions that aren't yanked, newest first
    /// @throws PackageSearchError.unreadable without a versions list
    static func parseVersions(_ object: [String: Any], host: String) throws -> [String] {
        guard let versions = object["versions"] as? [[String: Any]] else {
            throw PackageSearchError.unreadable(host)
        }
        return PackageVersion.newestFirst(versions.compactMap { version in
            (version["yanked"] as? Bool) == true ? nil : version["num"] as? String
        })
    }
}
