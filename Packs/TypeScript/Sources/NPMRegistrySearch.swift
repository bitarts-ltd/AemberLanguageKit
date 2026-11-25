/**
    @file NPMRegistrySearch.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Searching the npm registry
    @details
    NPMRegistrySearch asks the npm registry's search
    (/-/v1/search?text=) and a package's abbreviated metadata (the
    install-v1 document, a fraction of the full one) for its versions
    and dist-tags. The parsers are static, for tests with saved answers.
    Searching crates.io is the Rust pack's.
*/

import Foundation
import AemberLanguageKit

// MARK: - npm

/// @brief Searches the npm registry
final class NPMRegistrySearch: PackageSearchSource {

    /// The registry
    let baseURL: URL
    private let http: PackageHTTP

    /// @brief Creates the source.
    /// @param baseURL The registry's address
    /// @param http The client
    init(baseURL: URL = URL(string: "https://registry.npmjs.org")!, http: PackageHTTP = PackageHTTP()) {
        self.baseURL = baseURL
        self.http = http
    }

    func search(_ text: String) async throws -> [PackageSearchResult] {
        let url = URL(string: baseURL.absoluteString + "/-/v1/search?size=25&text=" + text.packageURLComponent)!
        return try Self.parseSearch(await http.object(url), host: url.host ?? "")
    }

    func details(of result: PackageSearchResult) async throws -> PackageSearchDetails {
        // A scoped name keeps its @ and has its / encoded
        let name = result.location.hasPrefix("@")
            ? "@" + String(result.location.dropFirst()).packageURLComponent
            : result.location.packageURLComponent
        let url = URL(string: baseURL.absoluteString + "/" + name)!
        let object = try await http.object(url, accept: "application/vnd.npm.install-v1+json")
        return PackageSearchDetails(summary: result.summary, versions: try Self.parseVersions(object, host: url.host ?? ""))
    }

    /// @brief Reads a search's answer.
    /// @param object The answer
    /// @param host The server, for the error
    /// @return The packages, in the registry's order
    /// @throws PackageSearchError.unreadable without an objects list
    static func parseSearch(_ object: [String: Any], host: String) throws -> [PackageSearchResult] {
        guard let objects = object["objects"] as? [[String: Any]] else {
            throw PackageSearchError.unreadable(host)
        }
        return objects.compactMap { entry in
            guard let package = entry["package"] as? [String: Any], let name = package["name"] as? String else {
                return nil
            }
            return PackageSearchResult(
                name: name,
                location: name,
                summary: (package["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                latestVersion: package["version"] as? String
            )
        }
    }

    /// @brief Reads a package's abbreviated metadata.
    /// @detail
    /// The latest dist-tag comes first, then the rest newest first.
    /// @param object The document
    /// @param host The server, for the error
    /// @return The versions
    /// @throws PackageSearchError.unreadable without a versions object
    static func parseVersions(_ object: [String: Any], host: String) throws -> [String] {
        guard let versions = object["versions"] as? [String: Any] else {
            throw PackageSearchError.unreadable(host)
        }
        var sorted = PackageVersion.newestFirst(Array(versions.keys))
        if let latest = (object["dist-tags"] as? [String: Any])?["latest"] as? String,
           let index = sorted.firstIndex(of: latest) {
            sorted.remove(at: index)
            sorted.insert(latest, at: 0)
        }
        return sorted
    }
}
