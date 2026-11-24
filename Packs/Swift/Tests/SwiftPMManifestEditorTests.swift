/**
    @file SwiftPMManifestEditorTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Tests for taking a dependency out of Package.swift's text.
    @details
    The editor removes a .package(...) by url:, path: or id:, with its
    comma and its line (and a trailing comment), the .product(...) uses
    naming it in arrays, and bare names of it in targets' dependencies
    unless a target has that name; a rule change removes the declaration
    only. A last element without a trailing comma takes the comma
    before it, and a mid-line element the space after its comma.
    Manifests that build the list in code, or use a product outside an
    array, are refused (nil).
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import SwiftPack

@Suite("SwiftPMManifestEditor")
struct SwiftPMManifestEditorTests {

    private let folder = URL(fileURLWithPath: "/work/App")

    private let manifest = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "App",
            dependencies: [
                .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"), // nio
                .package(path: "../Kit"),
                .package(id: "scope.name", exact: "1.0.0")
            ],
            targets: [
                .target(name: "App", dependencies: [
                    .product(name: "NIO", package: "swift-nio"),
                    "Kit",
                    .product(name: "Name", package: "scope.name"),
                ]),
                .testTarget(name: "AppTests", dependencies: ["App", .product(name: "NIOCore", package: "swift-nio")]),
            ]
        )

        """

    private let nio = PackageDependency(
        name: "swift-nio",
        rule: .upToNextMajor("2.65.0"),
        location: "https://github.com/apple/swift-nio.git"
    )

    private let kit = PackageDependency(name: "kit", rule: .path("../Kit"), location: "/work/Kit")

    private let registry = PackageDependency(name: "scope.name", rule: .exact("1.0.0"), location: "scope.name")

    private func remove(_ dependency: PackageDependency, from text: String, products: Bool = true) -> String? {
        SwiftPMManifestEditor.removing(dependency, from: text, folder: folder, products: products)
    }

    @Test func removesURLDependencyAndItsProducts() throws {
        let result = try #require(remove(nio, from: manifest))
        #expect(result == """
            // swift-tools-version: 5.9
            import PackageDescription

            let package = Package(
                name: "App",
                dependencies: [
                    .package(path: "../Kit"),
                    .package(id: "scope.name", exact: "1.0.0")
                ],
                targets: [
                    .target(name: "App", dependencies: [
                        "Kit",
                        .product(name: "Name", package: "scope.name"),
                    ]),
                    .testTarget(name: "AppTests", dependencies: ["App"]),
                ]
            )

            """)
    }

    @Test func removesPathDependencyAndItsBareName() throws {
        let result = try #require(remove(kit, from: manifest))
        #expect(!result.contains("../Kit"))
        #expect(!result.contains("\"Kit\""))
        #expect(result.contains(".product(name: \"NIO\", package: \"swift-nio\"),"))
        // The target named App keeps its bare "App" dependency
        #expect(result.contains("dependencies: [\"App\", .product"))
    }

    @Test func removesRegistryDependencyTakingTheCommaBefore() throws {
        let result = try #require(remove(registry, from: manifest))
        #expect(result.contains("""
                    .package(path: "../Kit")
                ],
            """))
        #expect(!result.contains("scope.name"))
    }

    @Test func ruleChangeRemovesTheDeclarationOnly() throws {
        let result = try #require(remove(nio, from: manifest, products: false))
        #expect(!result.contains("swift-nio.git"))
        #expect(result.contains(".product(name: \"NIO\", package: \"swift-nio\")"))
    }

    @Test func midLineElementTakesTheSpaceAfterItsComma() throws {
        let text = """
            let package = Package(
                name: "A",
                dependencies: [.package(url: "https://x/a.git", from: "1.0.0"), .package(url: "https://x/b.git", from: "1.0.0")]
            )
            """
        let a = PackageDependency(name: "a", rule: .upToNextMajor("1.0.0"), location: "https://x/a.git")
        let result = try #require(remove(a, from: text))
        #expect(result.contains("dependencies: [.package(url: \"https://x/b.git\", from: \"1.0.0\")]"))
    }

    @Test func bareNameOfATargetIsKept() throws {
        let text = """
            let package = Package(
                name: "A",
                dependencies: [
                    .package(path: "../Kit"),
                ],
                targets: [
                    .target(name: "Kit"),
                    .target(name: "A", dependencies: ["Kit"]),
                ]
            )
            """
        let result = try #require(remove(kit, from: text))
        #expect(result.contains("dependencies: [\"Kit\"]"))
        #expect(!result.contains("../Kit"))
    }

    @Test func computedListIsRefused() {
        let text = """
            let deps: [Package.Dependency] = [.package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0")]
            let package = Package(name: "A", dependencies: deps)
            """
        #expect(remove(nio, from: text) == nil)
    }

    @Test func productOutsideAnArrayIsRefused() {
        let text = """
            var uses: [Target.Dependency] = []
            uses.append(.product(name: "NIO", package: "swift-nio"))
            let package = Package(
                name: "A",
                dependencies: [
                    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
                ],
                targets: [.target(name: "A", dependencies: uses)]
            )
            """
        #expect(remove(nio, from: text) == nil)
        // A rule change doesn't touch the products, so it can go ahead
        #expect(remove(nio, from: text, products: false) != nil)
    }

    @Test func unknownDependencyIsRefused() {
        let other = PackageDependency(name: "other", rule: .upToNextMajor("1.0.0"), location: "https://x/other.git")
        #expect(remove(other, from: manifest) == nil)
    }

    @Test func mergedJoinsOverlappingRanges() {
        let ranges = SwiftPMManifestEditor.merged([
            NSRange(location: 10, length: 5),
            NSRange(location: 0, length: 3),
            NSRange(location: 12, length: 6),
        ])
        #expect(ranges == [NSRange(location: 0, length: 3), NSRange(location: 10, length: 8)])
        #expect(SwiftPMManifestEditor.applying(ranges, to: "abcdefghijklmnopqrstu") == "defghijstu")
    }
}
