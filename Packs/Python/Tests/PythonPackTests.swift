/**
    @file PythonPackTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for the Python pack's contributions.
*/

import Foundation
import Testing
import AemberLanguageKit
@testable import PythonPack

/// @brief A context with nothing in it
private struct NoContext: BuildSystemContext {}

@Suite struct PythonPackTests {

    let pack = PythonPack()
    let output = URL(fileURLWithPath: "/tmp/out")

    @Test func definesPython() throws {
        let python = try #require(pack.languages.first)
        #expect(python.extensions == ["py", "pyw", "pyi"])
        #expect(python.shebangInterpreters == ["python"])
        #expect(python.grammar?.language() != nil)
        #expect(python.lineComment == "#")
        #expect(pack.languageServers.map(\.name) == ["pylsp"])
    }

    @Test func testsWithPytestAndHasNoBuild() throws {
        let system = PythonBuildSystem()
        let test = try system.command(for: .test, in: output, config: nil, filter: "adds", outputDirectory: output, context: NoContext())
        #expect(test.steps.map { [$0.executable] + $0.arguments } == [["pytest", "--junitxml=/tmp/out/junit.xml", "-k", "adds"]])
        #expect(test.report == BuildReportFile(URL(fileURLWithPath: "/tmp/out/junit.xml"), format: BuildReportFile.junit))
        let all = try system.command(for: .test, in: output, config: nil, filter: nil, outputDirectory: output, context: NoContext())
        #expect(all.steps.first?.arguments == ["--junitxml=/tmp/out/junit.xml"])
        #expect(throws: BuildCommandError.self) {
            try system.command(for: .build, in: output, config: nil, filter: nil, outputDirectory: output, context: NoContext())
        }
    }

    @Test func detectsItsMarkers() throws {
        for marker in ["pyproject.toml", "setup.py", "setup.cfg"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("py-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(PythonBuildSystem.detect(in: root) == nil)
            try Data().write(to: root.appendingPathComponent(marker))
            #expect(PythonBuildSystem.detect(in: root) != nil)
        }
    }
}
