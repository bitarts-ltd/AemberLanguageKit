/**
    @file PackageSearch.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Finding packages to add, and their versions
    @details
    The Add Package sheet searches a package manager's registry (or, for
    Swift, an index of packages) through a PackageSearchSource: search
    returns results with a description and latest version where the
    source has them, and versions lists a result's versions, newest
    first, for the version popup. Sources reach the network through
    PackageHTTP, which tests give a stubbed URLSession. PackageVersion
    orders version strings the way package managers do (numbers by
    value, a pre-release before its release). Searching is only ever
    started by the user, in the sheet; nothing here runs on its own.
*/

import Foundation

// MARK: - Results

/// @brief One package a search found
public struct PackageSearchResult: Equatable, Sendable {

    /// The name the sheet shows: a crate's or npm package's name, a
    /// Swift package's owner/repository, a registry identity
    public var name: String

    /// What the package manager is given to add it: the name, a git
    /// URL, or a registry identity (scope.name)
    public var location: String

    /// What the package is, if the source says
    public var summary: String?

    /// Its newest version, if the source says
    public var latestVersion: String?

    /// @brief A result.
    /// @param name The name shown
    /// @param location What the package manager is given
    /// @param summary What the package is
    /// @param latestVersion Its newest version
    /// @return The result
    public init(name: String, location: String, summary: String? = nil, latestVersion: String? = nil) {
        self.name = name
        self.location = location
        self.summary = summary
        self.latestVersion = latestVersion
    }
}

/// @brief More about a result than its search row: shown once it is
/// selected
public struct PackageSearchDetails: Equatable, Sendable {

    /// What the package is
    public var summary: String?

    /// Its versions, newest first
    public var versions: [String]

    /// Its products (SwiftPM), for the product popup
    public var products: [String] = []

    /// @brief Details.
    /// @param summary What the package is
    /// @param versions Its versions, newest first
    /// @param products Its products (SwiftPM)
    /// @return The details
    public init(summary: String? = nil, versions: [String], products: [String] = []) {
        self.summary = summary
        self.versions = versions
        self.products = products
    }
}

/// @brief Finds packages to add for one package manager
public protocol PackageSearchSource: AnyObject {

    /// @brief Searches for packages.
    /// @param text What the user typed
    /// @return The results, best first
    /// @throws PackageSearchError
    func search(_ text: String) async throws -> [PackageSearchResult]

    /// @brief A result's versions and what else the source knows.
    /// @param result The result
    /// @return Its details
    /// @throws PackageSearchError
    func details(of result: PackageSearchResult) async throws -> PackageSearchDetails

    /// When the list searched was fetched, for a source that searches a
    /// list it downloads (the Swift Package Index's); nil for others
    var listDate: Date? { get }

    /// Why an older copy of that list is in use, or nil when it's fresh
    var listNotice: String? { get }
}

extension PackageSearchSource {

    /// No list, by default
    public var listDate: Date? {
        nil
    }

    /// No notice, by default
    public var listNotice: String? {
        nil
    }
}

/// @brief Why a search or version list failed
@frozen
public enum PackageSearchError: Error, Equatable, Sendable {

    /// The server couldn't be reached
    case offline(String)

    /// The server answered with an error status
    case status(Int, String)

    /// The server wants a login Aember doesn't have
    case needsLogin(String)

    /// The answer wasn't what the source expects
    case unreadable(String)
}

// MARK: - HTTP

/// @brief GET requests for package searches
public final class PackageHTTP: @unchecked Sendable {

    /// The session requests go through
    public let session: URLSession

    /// @brief Creates the client.
    /// @param session The session; tests pass one with a stub protocol
    /// @return The client
    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// The User-Agent registries see (crates.io asks for one)
    public static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        // l10n-exempt: an HTTP header
        return "Aember/\(version) (macOS; package search)"
    }

    /// @brief Fetches a URL.
    /// @param url The URL
    /// @param accept The Accept header
    /// @return The body of a 2xx answer
    /// @throws PackageSearchError: .offline when it can't connect,
    /// .needsLogin for 401 and 403, .status for other errors
    public func get(_ url: URL, accept: String = "application/json") async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let host = url.host ?? url.absoluteString
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PackageSearchError.offline(host)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        switch status {
        case 200..<300:
            return data
        case 401, 403:
            throw PackageSearchError.needsLogin(host)
        default:
            throw PackageSearchError.status(status, host)
        }
    }

    /// @brief Fetches a URL's JSON object.
    /// @param url The URL
    /// @param accept The Accept header
    /// @return The object
    /// @throws PackageSearchError, .unreadable if it isn't an object
    public func object(_ url: URL, accept: String = "application/json") async throws -> [String: Any] {
        let data = try await get(url, accept: accept)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PackageSearchError.unreadable(url.host ?? url.absoluteString)
        }
        return object
    }
}

// MARK: - Versions

/// @brief Version strings, ordered as package managers order them
public enum PackageVersion: Sendable {

    /// @brief The parts of a version: its numbers and its pre-release.
    /// @detail
    /// A leading "v" is dropped (git tags); build metadata after "+"
    /// is ignored.
    /// @param text The version (1.2.3, v2.0.0-beta.1)
    /// @return The numbers and pre-release text, or nil if it doesn't
    /// start with a number
    public static func parts(_ text: String) -> (numbers: [Int], prerelease: String?)? {
        var value = Substring(text)
        if value.first == "v" || value.first == "V" {
            value = value.dropFirst()
        }
        value = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? value
        let pieces = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = pieces[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        let prerelease = pieces.count > 1 ? String(pieces[1]) : nil
        return (numbers.compactMap { $0 }, prerelease)
    }

    /// @brief Whether a version is a plain release (no pre-release).
    /// @param text The version
    /// @return true for 1.2.3, false for 1.2.3-beta or not a version
    public static func isRelease(_ text: String) -> Bool {
        guard let parts = parts(text) else { return false }
        return parts.prerelease == nil
    }

    /// @brief Whether one version comes before another.
    /// @detail
    /// Numbers compare by value, a missing one as 0; at equal numbers
    /// a pre-release comes before the release, and pre-releases compare
    /// by their dot-separated identifiers (numbers by value, before
    /// words). Strings that aren't versions come before every version,
    /// in text order.
    /// @param lhs A version
    /// @param rhs Another
    /// @return true if lhs is older
    public static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        guard let left = parts(lhs) else {
            return parts(rhs) != nil || lhs < rhs
        }
        guard let right = parts(rhs) else { return false }
        for index in 0..<max(left.numbers.count, right.numbers.count) {
            let a = index < left.numbers.count ? left.numbers[index] : 0
            let b = index < right.numbers.count ? right.numbers[index] : 0
            if a != b {
                return a < b
            }
        }
        switch (left.prerelease, right.prerelease) {
        case (nil, nil), (nil, _?):
            return false
        case (_?, nil):
            return true
        case (let a?, let b?):
            return prereleaseIsOlder(a, than: b)
        }
    }

    /// @brief Orders two pre-releases by their identifiers.
    private static func prereleaseIsOlder(_ lhs: String, than rhs: String) -> Bool {
        let left = lhs.split(separator: ".")
        let right = rhs.split(separator: ".")
        for (a, b) in zip(left, right) where a != b {
            switch (Int(a), Int(b)) {
            case (let x?, let y?):
                return x < y
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return a < b
            }
        }
        return left.count < right.count
    }

    /// @brief Versions, newest first, without duplicates.
    /// @param versions The versions
    /// @return Them sorted
    public static func newestFirst(_ versions: [String]) -> [String] {
        var seen = Set<String>()
        return versions.filter { seen.insert($0).inserted }.sorted { isOlder($1, than: $0) }
    }

    /// @brief The newest release in a list, else the newest version.
    /// @param versions The versions
    /// @return The version, or nil for an empty list
    public static func latest(_ versions: [String]) -> String? {
        let sorted = newestFirst(versions)
        return sorted.first(where: isRelease) ?? sorted.first
    }
}

// MARK: - Query Encoding

extension String {

    /// @brief The string as one URL query value or path segment: every
    /// character but letters, digits and -._~ percent-encoded.
    public var packageURLComponent: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
