/**
    @file SwiftPMChecksTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for checking Swift packages for updates.
    @details
    Git tags against a fake tool runner: the newest the rule allows and
    the newest there is, a repository that can't be listed, and
    branches and folders left alone. A live test runs the real git
    against GitHub; it reaches the network, so it runs only with
    AEMBER_LIVE_PACKAGE_CHECKS set. Moved from Aember's
    PackageCheckTests with the backend.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import SwiftPack

@Suite("SwiftPM checks", .timeLimit(.minutes(2)))
struct SwiftPMChecksTests {

    @Test func swiftCheckListsTags() async throws {
        let nio = "https://github.com/apple/swift-nio.git"
        let atomics = "https://github.com/apple/swift-atomics.git"
        let broken = "https://x.test/broken.git"
        let graph = PackageGraph(
            rootName: "App",
            dependencies: [
                PackageDependency(name: "swift-nio", rule: .upToNextMajor("2.65.0"), location: nio, resolvedID: "swift-nio"),
                PackageDependency(name: "kit", rule: .path("../kit"), resolvedID: "kit"),
            ],
            packages: [
                ResolvedPackage(id: "swift-nio", name: "swift-nio", version: "2.70.0", source: .git(nio)),
                ResolvedPackage(id: "swift-atomics", name: "swift-atomics", version: "1.2.0", source: .git(atomics)),
                ResolvedPackage(id: "branchy", name: "branchy", branch: "main", source: .git("https://x.test/branchy.git")),
                ResolvedPackage(id: "kit", name: "kit", source: .path("../kit")),
                ResolvedPackage(id: "broken", name: "broken", version: "1.0.0", source: .git(broken)),
            ]
        )
        let runner = FakePackageToolRunner()
        runner.installed.insert("git")
        let tags = ["2.70.0", "2.72.0", "3.0.0", "3.1.0-beta.1"].map { "abc\trefs/tags/\($0)" }.joined(separator: "\n")
        runner.answer("git ls-remote --tags --refs \(nio)", with: Data(tags.utf8))
        runner.answer("git ls-remote --tags --refs \(atomics)", with: Data("abc\trefs/tags/1.2.0\n".utf8))
        let temp = try PackageTempFolder()
        defer { temp.remove() }
        let manifest = try temp.write("Package.swift", "")
        let backend = SwiftPMBackend(manifestURL: manifest, runner: runner)
        let result = await backend.check(graph: graph, http: PackageHTTP(session: StubHTTPService().session))
        #expect(result.updates == [PackageUpdate(packageID: "swift-nio", current: "2.70.0", compatible: "2.72.0", latest: "3.0.0")])
        #expect(result.problems.count == 1)
        #expect(result.problems.first?.contains("broken") == true)
        // Branches and folders aren't asked about
        #expect(!runner.commands.contains { $0.line.contains("branchy") })
        #expect(result.advisories.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AEMBER_LIVE_PACKAGE_CHECKS"] != nil))
    func liveChecksReachTheRegistries() async throws {
        let runner = ProcessPackageToolRunner()
        let http = PackageHTTP()
        let temp = try PackageTempFolder()
        defer { temp.remove() }

        let swift = ResolvedPackage(id: "swift-argument-parser", name: "swift-argument-parser", version: "1.0.0", source: .git("https://github.com/apple/swift-argument-parser.git"))
        let graph = PackageGraph(
            rootName: "App",
            dependencies: [PackageDependency(name: "swift-argument-parser", rule: .upToNextMinor("1.0.0"), resolvedID: swift.id)],
            packages: [swift]
        )
        let manifest = try temp.write("swift/Package.swift", "")
        let result = await SwiftPMBackend(manifestURL: manifest, runner: runner).check(graph: graph, http: http)
        let update = try #require(result.updates.first)
        #expect(update.compatible?.hasPrefix("1.0.") == true)
        #expect(update.latest.map { PackageVersion.isOlder("1.5.0", than: $0) } == true)
    }
}
