/**
    @file XcodeProjectLookupTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for XcodeProjectLookup.
    @details
    The bundle rule (workspace over project; the one named like the
    folder, else the first by name), the scheme rule (named like the
    workspace or project, else the first), parsing `xcodebuild -list
    -json`, and listing with a fake xcodebuild: its arguments, the
    project's xcode environment, and failures.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import SwiftPack

@Suite("XcodeProjectLookup")
struct XcodeProjectLookupTests {

    // MARK: - Bundles

    /// @brief Among bundles of one kind, the one named like the folder
    /// wins, else the first by name; other kinds are ignored.
    @Test func preferredBundle() {
        let names = ["Zed.xcodeproj", "App.xcodeproj", "Beta.xcodeproj",
                     "App.xcworkspace", "README.md"]
        #expect(XcodeProjectLookup.preferredBundle(
            names, withExtension: "xcodeproj", folder: "Beta"
        ) == "Beta.xcodeproj")
        #expect(XcodeProjectLookup.preferredBundle(
            names, withExtension: "xcodeproj", folder: "Other"
        ) == "App.xcodeproj")
        #expect(XcodeProjectLookup.preferredBundle(
            names, withExtension: "xcworkspace", folder: "Other"
        ) == "App.xcworkspace")
        #expect(XcodeProjectLookup.preferredBundle(
            ["README.md"], withExtension: "xcodeproj", folder: "App"
        ) == nil)
    }

    /// @brief A folder's bundles, and the one container to build: the
    /// workspace over the project.
    @Test func bundlesAndContainer() throws {
        let fixture = try BuildSystemFixture()
        #expect(XcodeProjectLookup.container(in: fixture.root) == nil)

        try fixture.makeDirectory("B.xcodeproj")
        try fixture.makeDirectory("A.xcodeproj")
        let projectOnly = try #require(
            XcodeProjectLookup.container(in: fixture.root)
        )
        #expect(projectOnly.workspace == nil)
        #expect(projectOnly.project == "A.xcodeproj")

        try fixture.makeDirectory("W.xcworkspace")
        let bundles = XcodeProjectLookup.bundles(in: fixture.root)
        #expect(bundles.workspace == "W.xcworkspace")
        #expect(bundles.project == "A.xcodeproj")
        let both = try #require(XcodeProjectLookup.container(in: fixture.root))
        #expect(both.workspace == "W.xcworkspace")
        #expect(both.project == nil)
    }

    /// @brief A folder that can't be read has no bundles.
    @Test func missingFolder() throws {
        let fixture = try BuildSystemFixture()
        let bundles = XcodeProjectLookup.bundles(in: fixture.url("missing"))
        #expect(bundles.workspace == nil)
        #expect(bundles.project == nil)
    }

    // MARK: - Schemes

    /// @brief The scheme named like the container wins, else the first.
    @Test func preferredScheme() {
        #expect(XcodeProjectLookup.preferredScheme(
            ["AppTests", "App"], named: "App"
        ) == "App")
        #expect(XcodeProjectLookup.preferredScheme(["A", "B"], named: "C") == "A")
        #expect(XcodeProjectLookup.preferredScheme(["A", "B"], named: nil) == "A")
        #expect(XcodeProjectLookup.preferredScheme([], named: "A") == nil)
    }

    /// @brief The schemes in xcodebuild -list -json, project or
    /// workspace.
    @Test func schemesFromList() {
        let workspace = #"{"workspace":{"name":"T","schemes":["T-Package"]}}"#
        let project = #"{"project":{"name":"A","schemes":["A","B"],"targets":[]}}"#
        #expect(XcodeProjectLookup.schemes(fromListJSON: Data(workspace.utf8))
            == ["T-Package"])
        #expect(XcodeProjectLookup.schemes(fromListJSON: Data(project.utf8))
            == ["A", "B"])
        #expect(XcodeProjectLookup.schemes(fromListJSON: Data()).isEmpty)
        #expect(XcodeProjectLookup.schemes(
            fromListJSON: Data("Schemes:\n    App\n".utf8)
        ).isEmpty)
    }

    /// @brief Listing runs xcodebuild -list -json for the workspace in
    /// the project folder, with the project's xcode environment, and
    /// picks the scheme named like the workspace.
    @Test func listsWithXcodebuild() throws {
        let fixture = try BuildSystemFixture()
        try fixture.write(".aember/xcode-env", "LOOKUP_TEST=from-env\n")
        let xcodebuild = try fixture.writeScript("tools/xcodebuild", """
            printf '%s\\n' "$@" > "\(fixture.url("args.txt").path)"
            printf '%s\\n' "$PWD" "$LOOKUP_TEST" > "\(fixture.url("env.txt").path)"
            echo '{"workspace":{"name":"App","schemes":["AppTests","App"]}}'
            """)
        let lookup = XcodeProjectLookup(xcodebuildPath: xcodebuild.path)

        #expect(lookup.scheme(
            in: fixture.root,
            workspace: "App.xcworkspace",
            project: "App.xcodeproj"
        ) == "App")
        #expect(try fixture.read("args.txt")
            == "-list\n-json\n-workspace\nApp.xcworkspace\n")
        let env = try fixture.read("env.txt").split(separator: "\n")
        #expect(env.last == "from-env")
        #expect(env.first.map {
            URL(fileURLWithPath: String($0)).resolvingSymlinksInPath()
        } == fixture.root.resolvingSymlinksInPath())

        _ = lookup.schemes(in: fixture.root, workspace: nil, project: "App.xcodeproj")
        #expect(try fixture.read("args.txt")
            == "-list\n-json\n-project\nApp.xcodeproj\n")
    }

    /// @brief A failing or missing xcodebuild lists no schemes.
    @Test func listingFails() throws {
        let fixture = try BuildSystemFixture()
        let failing = try fixture.writeScript(
            "tools/xcodebuild", "echo 'xcodebuild: error' >&2; exit 66"
        )
        #expect(XcodeProjectLookup(xcodebuildPath: failing.path).schemes(
            in: fixture.root, workspace: nil, project: "App.xcodeproj"
        ).isEmpty)
        #expect(XcodeProjectLookup(
            xcodebuildPath: fixture.url("tools/missing").path
        ).scheme(in: fixture.root, workspace: nil, project: "App.xcodeproj")
            == nil)
    }
}
