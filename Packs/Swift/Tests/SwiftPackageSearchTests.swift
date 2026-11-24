/**
    @file SwiftPackageSearchTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Tests for finding Swift packages.
    @details
    git ls-remote's tags as versions; the Swift Package Index's list
    (an excerpt of the real packages.json) searched and ranked; an
    owner's package collection (an excerpt of vapor's) read for
    summaries, versions and products; the daily download against a
    stub server: fresh, kept for a day, stale, failed and malformed
    falling back to the last copy; versions from git tags when the
    collection lacks the package. Registry configuration (the project's
    over the user's, a scope's over the default) and release lists
    against a stub registry (200, 401, 404); registry pins' sources;
    and dump-package's targets.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import SwiftPack

/// The Fixtures folder beside this file
private let fixtures = PackageFixtures()

@Suite("Swift package search", .serialized)
struct SwiftPackageSearchTests {

    // MARK: - Git Tags

    @Test func tagsBecomeVersions() {
        let output = """
            1111111\trefs/tags/1.0.0
            2222222\trefs/tags/v1.2.0
            3333333\trefs/tags/v1.2.0^{}
            4444444\trefs/tags/latest
            5555555\trefs/tags/2.0.0-beta.1
            6666666\trefs/tags/release-3
            7777777\trefs/tags/7
            8888888\trefs/tags/1.10.0

            """
        #expect(GitTags.parse(output) == ["2.0.0-beta.1", "1.10.0", "1.2.0", "1.0.0"])
    }

    @Test func tagsComeFromGit() throws {
        let runner = FakePackageToolRunner()
        runner.installed.insert("git")
        let url = "https://example.com/kit.git"
        runner.answer("git ls-remote --tags --refs \(url)", with: Data("1\trefs/tags/0.1.0\n2\trefs/tags/0.2.0\n".utf8))
        #expect(try GitTags.versions(of: url, runner: runner) == ["0.2.0", "0.1.0"])
        #expect(throws: PackageError.self) {
            try GitTags.versions(of: "-x", runner: runner)
        }
        runner.answer("git ls-remote --tags --refs https://example.com/gone.git", with: Data(), status: 128, error: "fatal: not found")
        #expect(throws: PackageError.toolFailed(command: "git ls-remote --tags https://example.com/gone.git", message: "fatal: not found")) {
            try GitTags.versions(of: "https://example.com/gone.git", runner: runner)
        }
    }

    // MARK: - The List

    static func list() throws -> [String] {
        try SwiftPackageIndexSearch.parseList(fixtures.data("spi-packages.json"), host: "")
    }

    @Test func ownersAndRepositories() {
        #expect(SwiftPackageIndexSearch.ownerAndRepository(of: "https://github.com/apple/swift-nio.git")! == ("apple", "swift-nio"))
        #expect(SwiftPackageIndexSearch.ownerAndRepository(of: "git@github.com:vapor/vapor.git")! == ("vapor", "vapor"))
        #expect(SwiftPackageIndexSearch.ownerAndRepository(of: "kit") == nil)
        #expect(SwiftPackageIndexSearch.isURL("https://x/y"))
        #expect(SwiftPackageIndexSearch.isURL("git@github.com:a/b.git"))
        #expect(!SwiftPackageIndexSearch.isURL("swift-nio"))
    }

    @Test func listRanksNamesFirst() throws {
        let list = try Self.list()
        #expect(list.count > 20)
        let nio = SwiftPackageIndexSearch.rank(list, query: "swift-nio")
        #expect(nio.first?.name == "apple/swift-nio")
        #expect(nio.first?.location.lowercased() == "https://github.com/apple/swift-nio.git")
        // A word of the name: swift-collections for "collections"
        #expect(SwiftPackageIndexSearch.rank(list, query: "Collections").first?.name == "apple/swift-collections")
        // An owner's packages after names
        let vapor = SwiftPackageIndexSearch.rank(list, query: "vapor")
        #expect(vapor.first?.name == "vapor/vapor")
        // owner/repository
        let algorithms = SwiftPackageIndexSearch.rank(list, query: "apple/swift-alg")
        #expect(algorithms.map(\.name) == ["apple/swift-algorithms"])
        #expect(SwiftPackageIndexSearch.rank(list, query: "zzzz-nothing").isEmpty)
        let many = SwiftPackageIndexSearch.rank((0..<200).map { "https://github.com/o/kit\($0).git" }, query: "kit")
        #expect(many.count == SwiftPackageIndexSearch.resultLimit)
        #expect(many.first?.name == "o/kit0")
    }

    @Test func collectionGivesDetails() throws {
        let collection = try fixtures.object("spi-collection-vapor.json")
        let details = try #require(SwiftPackageIndexSearch.details(of: "https://github.com/Vapor/vapor", in: collection))
        #expect(details.versions.first == "5.0.0-beta.4")
        #expect(details.versions.contains("4.122.4"))
        #expect(details.products.contains("Vapor"))
        #expect(details.summary?.isEmpty == false)
        let apns = try #require(SwiftPackageIndexSearch.details(of: "https://github.com/vapor/apns.git", in: collection))
        #expect(apns.products == ["VaporAPNS"])
        #expect(SwiftPackageIndexSearch.details(of: "https://github.com/vapor/other.git", in: collection) == nil)
    }

    // MARK: - Downloading

    /// @brief A source on a stub server and a temporary cache, with a
    /// clock the test moves.
    final class Harness {
        let service = StubHTTPService()
        let cache: PackageTempFolder
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let runner = FakePackageToolRunner()

        init() throws {
            cache = try PackageTempFolder()
            runner.installed.insert("git")
        }

        func source() -> SwiftPackageIndexSearch {
            SwiftPackageIndexSearch(
                listURL: URL(string: "https://raw.test/packages.json")!,
                indexURL: URL(string: "https://index.test")!,
                cacheFolder: cache.url,
                http: PackageHTTP(session: service.session),
                runner: runner,
                now: { [unowned self] in self.now }
            )
        }

        func serve(_ list: Any, status: Int = 200) {
            service.on("/packages.json") { _ in .json(status, list) }
        }

        var downloads: Int {
            service.requests(to: "/packages.json").count
        }
    }

    @Test func listIsDownloadedOnceADay() async throws {
        let harness = try Harness()
        defer { harness.cache.remove() }
        harness.serve(["https://github.com/apple/swift-nio.git"])
        let source = harness.source()
        #expect(try await source.search("nio").map(\.name) == ["apple/swift-nio"])
        #expect(harness.downloads == 1)
        #expect(source.listDate == harness.now)
        #expect(source.listNotice == nil)
        _ = try await source.search("swift")
        #expect(harness.downloads == 1)

        // A new source reads the copy on disk within the day
        harness.now += 3600
        harness.serve(["https://github.com/apple/swift-collections.git"])
        #expect(try await harness.source().search("nio").count == 1)
        #expect(harness.downloads == 1)

        // A day later it downloads again
        harness.now += 24 * 3600
        let later = harness.source()
        #expect(try await later.search("collections").map(\.name) == ["apple/swift-collections"])
        #expect(harness.downloads == 2)
    }

    @Test func failedOrMalformedDownloadsUseTheLastCopy() async throws {
        let harness = try Harness()
        defer { harness.cache.remove() }
        // Nothing yet, and a malformed answer: an error
        harness.serve(["not": "a list"])
        await #expect(throws: PackageSearchError.unreadable("raw.test")) {
            try await harness.source().search("nio")
        }
        harness.serve(["https://github.com/apple/swift-nio.git"])
        _ = try await harness.source().search("nio")

        harness.now += 2 * 24 * 3600
        harness.serve([:], status: 500)
        let failed = harness.source()
        #expect(try await failed.search("nio").count == 1)
        // The error's words are Aember's (its PackageSearchError messages)
        #expect(failed.listNotice?.hasPrefix("Couldn’t update the package list: ") == true)
        #expect(failed.listDate == harness.now - 2 * 24 * 3600)

        harness.serve(["not": "a list"])
        let malformed = harness.source()
        #expect(try await malformed.search("nio").count == 1)
        #expect(malformed.listNotice != nil)
    }

    @Test func urlsAreResultsOfTheirOwn() async throws {
        let harness = try Harness()
        defer { harness.cache.remove() }
        let results = try await harness.source().search("  https://example.com/team/kit.git ")
        #expect(results == [PackageSearchResult(name: "team/kit", location: "https://example.com/team/kit.git")])
        #expect(harness.downloads == 0)
        #expect(try await harness.source().search("  ").isEmpty)
    }

    @Test func detailsFromTheCollectionElseTags() async throws {
        let harness = try Harness()
        defer { harness.cache.remove() }
        let collection = try fixtures.object("spi-collection-vapor.json")
        harness.service.on("/vapor/collection.json") { _ in .json(200, collection) }
        let source = harness.source()
        let vapor = try await source.details(of: PackageSearchResult(name: "vapor/vapor", location: "https://github.com/vapor/vapor.git"))
        #expect(vapor.products.contains("Vapor"))
        #expect(harness.service.requests(to: "/vapor/collection.json").count == 1)

        // Not in the collection: its tags; the collection is kept a day
        let other = "https://github.com/vapor/other.git"
        harness.runner.answer("git ls-remote --tags --refs \(other)", with: Data("1\trefs/tags/v0.3.0\n".utf8))
        let tags = try await source.details(of: PackageSearchResult(name: "vapor/other", location: other))
        #expect(tags.versions == ["0.3.0"])
        #expect(tags.products.isEmpty)
        #expect(harness.service.requests(to: "/vapor/collection.json").count == 1)

        // A collection that can't be fetched: tags too
        let lone = "https://github.com/lone/kit.git"
        harness.runner.answer("git ls-remote --tags --refs \(lone)", with: Data("1\trefs/tags/1.0.0\n".utf8))
        #expect(try await source.details(of: PackageSearchResult(name: "lone/kit", location: lone)).versions == ["1.0.0"])
    }

    // MARK: - Registries

    @Test func registryConfiguration() throws {
        let folder = try PackageTempFolder()
        defer { folder.remove() }
        let home = folder.url.appendingPathComponent("home")
        let project = folder.url.appendingPathComponent("project")
        try folder.write("home/.swiftpm/configuration/registries.json", """
            {"registries": {"[default]": {"url": "https://user.test"}, "acme": {"url": "https://acme-user.test"}, "tools": {"url": "https://tools.test"}}, "version": 1}
            """)
        try folder.write("project/.swiftpm/configuration/registries.json", """
            {"registries": {"Acme": {"url": "https://acme.test/swift"}}, "version": 1}
            """)
        let configuration = SwiftRegistryConfiguration.load(for: project, home: home)
        #expect(!configuration.isEmpty)
        #expect(configuration.registry(for: "acme.Kit")?.absoluteString == "https://acme.test/swift")
        #expect(configuration.registry(for: "tools.lint")?.absoluteString == "https://tools.test")
        #expect(configuration.registry(for: "other.thing")?.absoluteString == "https://user.test")
        let none = SwiftRegistryConfiguration.load(for: project, home: folder.url.appendingPathComponent("nobody"))
        #expect(none.registry(for: "other.thing") == nil)
        #expect(SwiftRegistryConfiguration.load(for: folder.url, home: folder.url).isEmpty)
        #expect(SwiftRegistryConfiguration.parse(Data("nonsense".utf8)).isEmpty)
    }

    @Test func registryReleases() async throws {
        let service = StubHTTPService()
        service.on("/swift/acme/kit") { _ in
            .json(200, ["releases": ["1.0.0": ["url": "x"], "1.1.0": ["url": "y"], "1.2.0": ["url": "z", "problem": ["status": 410]]]])
        }
        service.on("/swift/acme/secret") { _ in .json(401, [:]) }
        let configuration = SwiftRegistryConfiguration(scoped: ["acme": URL(string: "https://registry.test/swift")!])
        let source = SwiftRegistrySearch(configuration: configuration, http: PackageHTTP(session: service.session))
        let found = try await source.search(" acme.kit ")
        #expect(found == [PackageSearchResult(name: "acme.kit", location: "acme.kit", summary: "registry.test")])
        #expect(try await source.search("not an identity").isEmpty)
        let details = try await source.details(of: found[0])
        #expect(details.versions == ["1.1.0", "1.0.0"])
        #expect(service.requests(to: "/swift/acme/kit").first?.headers["Accept"] == "application/vnd.swift.registry.v1+json")
        await #expect(throws: PackageSearchError.needsLogin("registry.test")) {
            try await source.details(of: PackageSearchResult(name: "acme.secret", location: "acme.secret"))
        }
        await #expect(throws: PackageSearchError.status(404, "registry.test")) {
            try await source.details(of: PackageSearchResult(name: "acme.gone", location: "acme.gone"))
        }
        // No registry for the scope: nothing to list
        #expect(try await source.details(of: PackageSearchResult(name: "other.kit", location: "other.kit")).versions.isEmpty)
    }

    @Test func registryPinsSayTheirRegistry() throws {
        let dump = SwiftPMBackend.Dump(name: "App", dependencies: [PackageDependency(name: "acme.Kit", rule: .upToNextMajor("1.0.0"), location: "acme.Kit")])
        let pins = [SwiftPMBackend.Pin(identity: "acme.kit", kind: "registry", location: "", version: "1.1.0")]
        let configuration = SwiftRegistryConfiguration(scoped: ["acme": URL(string: "https://registry.test/swift")!])
        let graph = SwiftPMBackend.graph(dump: dump, pins: pins, tree: nil, checkouts: URL(fileURLWithPath: "/nonexistent"), registries: configuration)
        #expect(graph.package("acme.kit")?.source == .registry("https://registry.test/swift"))
        #expect(graph.dependencies.first?.resolvedID == "acme.kit")
    }

    @Test func dumpListsTargets() throws {
        let dump = try SwiftPMBackend.parseDump(fixtures.data("swiftpm-dump-app.json"), folder: URL(fileURLWithPath: "/work/app"))
        #expect(dump.targets == ["App", "AppTests"])
        let graph = SwiftPMBackend.graph(dump: dump, pins: nil, tree: nil, checkouts: URL(fileURLWithPath: "/nonexistent"))
        #expect(graph.targets == ["App", "AppTests"])
        let plugins = try SwiftPMBackend.parseDump(Data("""
            {"name": "P", "dependencies": [], "targets": [{"name": "Lib", "type": "regular"}, {"name": "Gen", "type": "plugin"}, {"name": "Sys", "type": "system"}, {"name": "Tool", "type": "executable"}]}
            """.utf8), folder: URL(fileURLWithPath: "/work"))
        #expect(plugins.targets == ["Lib", "Tool"])
    }
}
