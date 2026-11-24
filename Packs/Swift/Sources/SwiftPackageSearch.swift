/**
    @file SwiftPackageSearch.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Finding Swift packages: the Swift Package Index, git tags and
    package registries
    @details
    No Swift registry protocol can search, so SwiftPackageIndexSearch
    searches the Swift Package Index's list of packages (packages.json
    in its PackageList repository, git URLs only), downloaded at most
    once a day into Application Support and searched locally by owner
    and repository name. A selected result's summary, versions and
    products come from its owner's package collection on the index
    (swiftpackageindex.com/<owner>/collection.json, SE-0291), kept a
    day too; its signature isn't checked, as it only fills the sheet.
    When the list can't be downloaded, the last copy is used and
    listNotice says so; when the collection doesn't have the package,
    its versions are its git tags (GitTags, `git ls-remote --tags`).
    A URL typed in the search field is a result of its own.

    SwiftRegistryConfiguration reads the package registries SwiftPM is
    set up with (the project's .swiftpm/configuration/registries.json
    over the user's ~/.swiftpm one, a scope's registry over the
    default), and SwiftRegistrySearch lists a registry package's
    releases (GET {registry}/{scope}/{name}) for the version popup. A
    registry that wants a login leaves the version to be typed.
*/

import Foundation
import AemberLanguageKit

// MARK: - Git Tags

/// @brief A git repository's version tags
enum GitTags {

    /// @brief Lists a repository's version tags.
    /// @param location Its URL or path
    /// @param runner Runs git
    /// @return The versions, newest first, without a leading "v"
    /// @throws PackageError when git is missing or fails
    static func versions(of location: String, runner: PackageToolRunner) throws -> [String] {
        let checked = try PackageCommand.checked(location)
        let result = try runner.run("git", arguments: ["ls-remote", "--tags", "--refs", checked], in: FileManager.default.temporaryDirectory)
        guard result.status == 0 else {
            // l10n-exempt: a command line
            throw PackageError.toolFailed(command: "git ls-remote --tags \(checked)", message: result.errorText)
        }
        return parse(String(decoding: result.output, as: UTF8.self))
    }

    /// @brief Reads ls-remote's output.
    /// @param output Lines of "<hash>\trefs/tags/<tag>"
    /// @return The tags that are versions, without a leading "v",
    /// newest first
    static func parse(_ output: String) -> [String] {
        let tags = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard let ref = line.split(separator: "\t").last, ref.hasPrefix("refs/tags/") else { return nil }
            var tag = String(ref.dropFirst("refs/tags/".count))
            if tag.hasSuffix("^{}") {
                tag.removeLast(3)
            }
            guard let parts = PackageVersion.parts(tag), parts.numbers.count >= 2 else { return nil }
            return tag.first == "v" || tag.first == "V" ? String(tag.dropFirst()) : tag
        }
        return PackageVersion.newestFirst(tags)
    }
}

// MARK: - Swift Package Index

/// @brief Searches the Swift Package Index's package list
final class SwiftPackageIndexSearch: PackageSearchSource {

    /// Where the package list is downloaded from
    static let defaultListURL = URL(string: "https://raw.githubusercontent.com/SwiftPackageIndex/PackageList/main/packages.json")!

    /// The index, for the owners' collections
    static let defaultIndexURL = URL(string: "https://swiftpackageindex.com")!

    /// How long a downloaded list or collection is used before it's
    /// downloaded again
    static let maxAge: TimeInterval = 24 * 60 * 60

    /// The most results a search returns
    static let resultLimit = 50

    /// @brief Where the list and collections are kept: Application
    /// Support/Aember/Packages.
    static var defaultCacheFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Aember/Packages", isDirectory: true)
    }

    let listURL: URL
    let indexURL: URL
    let cacheFolder: URL
    private let http: PackageHTTP
    private let runner: PackageToolRunner
    private let now: () -> Date
    private let lock = NSLock()
    private var list: [String]?
    private var storedListDate: Date?
    private var storedNotice: String?

    /// @brief Creates the source.
    /// @param listURL Where the package list is downloaded from
    /// @param indexURL The index, for collections
    /// @param cacheFolder Where downloads are kept
    /// @param http The client
    /// @param runner Runs git for tags
    /// @param now The clock
    init(
        listURL: URL = defaultListURL,
        indexURL: URL = defaultIndexURL,
        cacheFolder: URL = defaultCacheFolder,
        http: PackageHTTP = PackageHTTP(),
        runner: PackageToolRunner = ProcessPackageToolRunner(),
        now: @escaping () -> Date = Date.init
    ) {
        self.listURL = listURL
        self.indexURL = indexURL
        self.cacheFolder = cacheFolder
        self.http = http
        self.runner = runner
        self.now = now
    }

    /// When the list searched was downloaded, for the sheet
    var listDate: Date? {
        lock.withLock { storedListDate }
    }

    /// Why an older list is in use, or nil when it's fresh
    var listNotice: String? {
        lock.withLock { storedNotice }
    }

    private var listFile: URL {
        cacheFolder.appendingPathComponent("swift-packages.json")
    }

    func search(_ text: String) async throws -> [PackageSearchResult] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isURL(query) {
            return [Self.result(forURL: query)]
        }
        guard !query.isEmpty else { return [] }
        return Self.rank(try await packageList(), query: query)
    }

    func details(of result: PackageSearchResult) async throws -> PackageSearchDetails {
        if let (owner, _) = Self.ownerAndRepository(of: result.location),
           let collection = try? await collection(owner: owner),
           let details = Self.details(of: result.location, in: collection),
           !details.versions.isEmpty {
            return details
        }
        let runner = runner
        let location = result.location
        let versions = try await Task.detached { try GitTags.versions(of: location, runner: runner) }.value
        return PackageSearchDetails(summary: result.summary, versions: versions)
    }

    // MARK: The List

    /// @brief The package list: the copy on disk if less than a day
    /// old, else a new download, else the old copy.
    /// @return The packages' git URLs
    /// @throws PackageSearchError when there's no copy and the download
    /// fails
    func packageList() async throws -> [String] {
        if let list = lock.withLock({ list }), let date = listDate, now().timeIntervalSince(date) < Self.maxAge {
            return list
        }
        let cached = readCachedList()
        if let cached, now().timeIntervalSince(cached.date) < Self.maxAge {
            store(cached.urls, date: cached.date, notice: nil)
            return cached.urls
        }
        do {
            let data = try await http.get(listURL)
            let urls = try Self.parseList(data, host: listURL.host ?? "")
            try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
            try? data.write(to: listFile, options: .atomic)
            let date = now()
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: listFile.path)
            store(urls, date: date, notice: nil)
            return urls
        } catch {
            guard let cached else { throw error }
            let notice = String(
                format: PackStrings.text("Couldn’t update the package list: %@").localized,
                error.localizedDescription
            )
            store(cached.urls, date: cached.date, notice: notice)
            return cached.urls
        }
    }

    private func store(_ urls: [String], date: Date, notice: String?) {
        lock.withLock {
            list = urls
            storedListDate = date
            storedNotice = notice
        }
    }

    /// @brief The list on disk and when it was downloaded, if it reads.
    private func readCachedList() -> (urls: [String], date: Date)? {
        guard let data = try? Data(contentsOf: listFile),
              let urls = try? Self.parseList(data, host: ""),
              let date = (try? FileManager.default.attributesOfItem(atPath: listFile.path))?[.modificationDate] as? Date
        else {
            return nil
        }
        return (urls, date)
    }

    /// @brief Reads packages.json.
    /// @param data The file
    /// @param host The server, for the error
    /// @return The URLs
    /// @throws PackageSearchError.unreadable if it isn't an array of
    /// strings
    static func parseList(_ data: Data, host: String) throws -> [String] {
        guard let urls = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            throw PackageSearchError.unreadable(host)
        }
        return urls
    }

    // MARK: Ranking

    /// @brief A git URL's owner and repository.
    /// @param url The URL (https://github.com/apple/swift-nio.git)
    /// @return The owner and repository without .git, or nil
    static func ownerAndRepository(of url: String) -> (owner: String, repository: String)? {
        var parts = url.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var repository = parts.removeLast()
        if repository.hasSuffix(".git") {
            repository.removeLast(4)
        }
        let owner = parts.removeLast().split(separator: ":").last.map(String.init) ?? ""
        guard !owner.isEmpty, !repository.isEmpty else { return nil }
        return (owner, repository)
    }

    /// @brief Whether search text is a git URL to add as it is.
    static func isURL(_ text: String) -> Bool {
        text.contains("://") || text.hasPrefix("git@")
    }

    /// @brief The result for a URL typed in.
    static func result(forURL url: String) -> PackageSearchResult {
        let name = ownerAndRepository(of: url).map { "\($0.owner)/\($0.repository)" } ?? url
        return PackageSearchResult(name: name, location: url)
    }

    /// @brief Searches the list.
    /// @detail
    /// Ignoring case: the repository named as typed first, then one
    /// starting with it, then one with a word (between -, _ and .)
    /// starting with it, then the owner's packages, then a repository
    /// containing it. "owner/repo" text matches the start of both.
    /// Equal matches go shorter name first, then by name.
    /// @param urls The list
    /// @param query What was typed
    /// @return The best results, up to resultLimit
    static func rank(_ urls: [String], query: String) -> [PackageSearchResult] {
        let text = query.lowercased()
        var scored: [(score: Int, owner: String, repository: String, url: String)] = []
        let slash = text.firstIndex(of: "/")
        for url in urls {
            guard let (owner, repository) = ownerAndRepository(of: url) else { continue }
            let o = owner.lowercased()
            let r = repository.lowercased()
            let score: Int?
            if let slash {
                let wantedOwner = String(text[..<slash])
                let wantedRepository = String(text[text.index(after: slash)...])
                score = o == wantedOwner && r.hasPrefix(wantedRepository) ? (r == wantedRepository ? 0 : 1) : nil
            } else if r == text {
                score = 0
            } else if r.hasPrefix(text) {
                score = 1
            } else if r.split(whereSeparator: { "-_.".contains($0) }).contains(where: { $0.hasPrefix(text) }) {
                score = 2
            } else if o.hasPrefix(text) {
                score = 3
            } else if r.contains(text) {
                score = 4
            } else {
                score = nil
            }
            if let score {
                scored.append((score, owner, repository, url))
            }
        }
        scored.sort {
            if $0.score != $1.score {
                return $0.score < $1.score
            }
            if $0.repository.count != $1.repository.count {
                return $0.repository.count < $1.repository.count
            }
            return ($0.owner + "/" + $0.repository).lowercased() < ($1.owner + "/" + $1.repository).lowercased()
        }
        return scored.prefix(resultLimit).map {
            PackageSearchResult(name: "\($0.owner)/\($0.repository)", location: $0.url)
        }
    }

    // MARK: Collections

    /// @brief An owner's package collection: the copy on disk if less
    /// than a day old, else a download, else the old copy.
    /// @param owner The owner, as the list writes it
    /// @return The collection
    /// @throws PackageSearchError
    func collection(owner: String) async throws -> [String: Any] {
        let file = cacheFolder.appendingPathComponent("collections", isDirectory: true)
            .appendingPathComponent(owner.lowercased().packageURLComponent + ".json")
        let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        let cached = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let cached, let date, now().timeIntervalSince(date) < Self.maxAge {
            return cached
        }
        let url = indexURL.appendingPathComponent(owner).appendingPathComponent("collection.json")
        do {
            let data = try await http.get(url)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PackageSearchError.unreadable(url.host ?? "")
            }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: file.path)
            return object
        } catch {
            guard let cached else { throw error }
            return cached
        }
    }

    /// @brief A package's summary, versions and products from its
    /// owner's collection.
    /// @detail
    /// URLs match without case and .git. The products are the newest
    /// release's (else the newest version's), from its default tools
    /// version's manifest.
    /// @param url The package's URL
    /// @param collection The collection
    /// @return The details, or nil if the collection hasn't the package
    static func details(of url: String, in collection: [String: Any]) -> PackageSearchDetails? {
        func key(_ text: String) -> String {
            var value = text.lowercased()
            if value.hasSuffix(".git") {
                value.removeLast(4)
            }
            return value
        }
        let wanted = key(url)
        guard let packages = collection["packages"] as? [[String: Any]],
              let package = packages.first(where: { ($0["url"] as? String).map(key) == wanted })
        else {
            return nil
        }
        let versions = package["versions"] as? [[String: Any]] ?? []
        let names = PackageVersion.newestFirst(versions.compactMap { $0["version"] as? String })
        var products: [String] = []
        if let newest = PackageVersion.latest(names), let version = versions.first(where: { $0["version"] as? String == newest }),
           let manifests = version["manifests"] as? [String: Any] {
            let manifest = (version["defaultToolsVersion"] as? String).flatMap { manifests[$0] } ?? manifests.values.first
            products = ((manifest as? [String: Any])?["products"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        let summary = (package["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PackageSearchDetails(summary: summary?.isEmpty == false ? summary : nil, versions: names, products: products)
    }
}

// MARK: - Registries

/// @brief The Swift package registries SwiftPM is set up with
struct SwiftRegistryConfiguration: Equatable {

    /// The registry for scopes without their own
    var defaultRegistry: URL?

    /// Registries by scope, lower cased
    var scoped: [String: URL] = [:]

    /// Whether any registry is set up
    var isEmpty: Bool {
        defaultRegistry == nil && scoped.isEmpty
    }

    /// @brief The configuration for a project: its own file's entries
    /// over the user's.
    /// @param folder The package's folder
    /// @param home The user's home folder
    /// @return The configuration
    static func load(
        for folder: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SwiftRegistryConfiguration {
        let path = ".swiftpm/configuration/registries.json"
        let user = (try? Data(contentsOf: home.appendingPathComponent(path))).map(parse) ?? SwiftRegistryConfiguration()
        let project = (try? Data(contentsOf: folder.appendingPathComponent(path))).map(parse) ?? SwiftRegistryConfiguration()
        return project.over(user)
    }

    /// @brief Reads a registries.json.
    /// @detail
    /// "registries" maps "[default]" or a scope to {"url": ...}.
    /// @param data The file
    /// @return Its registries; none if it doesn't read
    static func parse(_ data: Data) -> SwiftRegistryConfiguration {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let registries = object["registries"] as? [String: Any]
        else {
            return SwiftRegistryConfiguration()
        }
        var configuration = SwiftRegistryConfiguration()
        for (scope, value) in registries {
            guard let text = (value as? [String: Any])?["url"] as? String, let url = URL(string: text) else { continue }
            if scope == "[default]" {
                configuration.defaultRegistry = url
            } else {
                configuration.scoped[scope.lowercased()] = url
            }
        }
        return configuration
    }

    /// @brief This configuration's entries over another's.
    func over(_ other: SwiftRegistryConfiguration) -> SwiftRegistryConfiguration {
        SwiftRegistryConfiguration(
            defaultRegistry: defaultRegistry ?? other.defaultRegistry,
            scoped: other.scoped.merging(scoped) { _, mine in mine }
        )
    }

    /// @brief The registry serving a package identity's scope.
    /// @param identity scope.name
    /// @return The scope's registry, else the default, else nil
    func registry(for identity: String) -> URL? {
        let scope = identity.split(separator: ".", maxSplits: 1).first.map { $0.lowercased() } ?? ""
        return scoped[scope] ?? defaultRegistry
    }
}

/// @brief A Swift package registry's releases, for identities typed in
final class SwiftRegistrySearch: PackageSearchSource {

    let configuration: SwiftRegistryConfiguration
    private let http: PackageHTTP

    /// @brief Creates the source.
    /// @param configuration The registries
    /// @param http The client
    init(configuration: SwiftRegistryConfiguration, http: PackageHTTP = PackageHTTP()) {
        self.configuration = configuration
        self.http = http
    }

    /// @brief Whether text is a registry identity (scope.name).
    static func isIdentity(_ text: String) -> Bool {
        SwiftPMBackend.sourceType(of: PackageSpec(name: text)) == "registry"
    }

    /// Registries can't search: an identity typed in is the result
    func search(_ text: String) async throws -> [PackageSearchResult] {
        let identity = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isIdentity(identity) else { return [] }
        return [PackageSearchResult(name: identity, location: identity, summary: configuration.registry(for: identity)?.host)]
    }

    func details(of result: PackageSearchResult) async throws -> PackageSearchDetails {
        guard let registry = configuration.registry(for: result.location) else {
            return PackageSearchDetails(summary: nil, versions: [])
        }
        let parts = result.location.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return PackageSearchDetails(summary: nil, versions: []) }
        let url = registry.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])
        let object = try await http.object(url, accept: "application/vnd.swift.registry.v1+json")
        return PackageSearchDetails(summary: result.summary, versions: try Self.parseReleases(object, host: url.host ?? ""))
    }

    /// @brief Reads a release list.
    /// @detail
    /// "releases" maps each version to its metadata; one with a
    /// "problem" (withdrawn) is left out.
    /// @param object The answer
    /// @param host The server, for the error
    /// @return The versions, newest first
    /// @throws PackageSearchError.unreadable without releases
    static func parseReleases(_ object: [String: Any], host: String) throws -> [String] {
        guard let releases = object["releases"] as? [String: Any] else {
            throw PackageSearchError.unreadable(host)
        }
        return PackageVersion.newestFirst(releases.compactMap { version, value in
            (value as? [String: Any])?["problem"] == nil ? version : nil
        })
    }
}
