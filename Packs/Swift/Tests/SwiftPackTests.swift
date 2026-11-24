/**
    @file SwiftPackTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Tests for what the Swift pack gives Aember.
    @details
    The Swift language with its grammar; sourcekit-lsp's arguments for
    a package, a project with buildServer.json and one without; the
    build systems in order; SwiftPM's Add Package style, its sources
    with and without a registry, and their search sources; and the
    pack's tree-sitter runtime parsing text with non-ASCII characters
    in UTF-16 ranges.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import SwiftPack
import TreeSitterSwift

@Suite struct SwiftPackTests {

    let pack = SwiftPack()

    @Test func definesSwift() throws {
        let swift = try #require(pack.languages.first)
        #expect(swift.id == "swift")
        #expect(swift.extensions == ["swift"])
        #expect(swift.docComment == "///")
        #expect(swift.grammar?.language() != nil)
        #expect(swift.queries.highlights?.isEmpty == false)
    }

    @Test func sourceKitLSPReadsTheDatabaseOnlyWhenNeeded() throws {
        let server = try #require(pack.languageServers.first)
        #expect(server.name == "sourcekit-lsp")
        #expect(server.restartTriggers == [.buildServerConfigured])
        #expect(server.locate != nil)
        let fixture = try BuildSystemFixture()
        #expect(server.arguments(for: fixture.root) == ["--compilation-db-search-path=.aember"])
        try fixture.write("buildServer.json", "{}")
        #expect(server.arguments(for: fixture.root).isEmpty)
        let package = try BuildSystemFixture()
        try package.write("Package.swift")
        #expect(server.arguments(for: package.root).isEmpty)
    }

    @Test func detectsPackagesBeforeXcodeProjects() {
        #expect(pack.buildSystems.map(\.identifier) == ["swiftpm", "xcode"])
        #expect(pack.buildSystems.map(\.priority) == [100, 500])
    }

    @Test func addsSwiftPackages() throws {
        #expect(pack.packageBackends.map { $0.identifier } == ["swiftpm"])
        #expect(SwiftPMBackend.addStyle == .swiftPackage)
        #expect(SwiftPMBackend.packageFileNames == ["Package.swift", "Package.resolved"])
        let fixture = try BuildSystemFixture()
        // The user's own registries.json may name a registry; this
        // checks the project's adds one
        try fixture.write(".swiftpm/configuration/registries.json", #"{"registries": {"[default]": {"url": "https://registry.test"}}, "version": 1}"#)
        #expect(SwiftPMBackend.addSources(in: fixture.root) == PackageAddSource.allCases)
        #expect(SwiftPMBackend.searchSource(for: .registry, in: fixture.root) is SwiftRegistrySearch)
        #expect(SwiftPMBackend.searchSource(for: .url, in: fixture.root) === SwiftPMBackend.packageIndex)
        #expect(SwiftPMBackend.searchSource(for: .folder, in: fixture.root) == nil)
        #expect(SwiftPMBackend.identity(ofLocation: "https://github.com/apple/swift-nio.git") == "swift-nio")
    }

    @Test func parsesUTF16Ranges() throws {
        let parser = Parser()
        try parser.setLanguage(try #require(tree_sitter_swift()))
        let text = "let é = \"ü\"\n"
        let root = try #require(parser.parse(text)?.rootNode)
        #expect(root.nodeType == "source_file")
        #expect(root.range == NSRange(location: 0, length: (text as NSString).length))
        var strings: [String] = []
        func walk(_ node: Node) {
            if node.nodeType == "line_string_literal" {
                strings.append((text as NSString).substring(with: node.range))
            }
            (0..<node.childCount).compactMap { node.child(at: $0) }.forEach(walk)
        }
        walk(root)
        #expect(strings == ["\"ü\""])
    }
}
