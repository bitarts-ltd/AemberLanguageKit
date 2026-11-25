/**
    @file TSCOutputParserTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for TSCOutputParser, against tsc's output.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import TypeScriptPack

struct TSCOutputParserTests {

    @Test func tscDiagnostics() throws {
        let parsed = parseOutput(try PackageFixtures().text("tsc.txt"), with: TSCOutputParser())
        let records = parsed.records
        #expect(records.diagnostics.map(\.path) == ["src/app.ts", "src/util/x.ts"])
        #expect(records.diagnostics[0].line == 3)
        #expect(records.diagnostics[0].column == 7)
        #expect(records.diagnostics[0].message.hasPrefix("TS2322: "))
    }

    @Test func compilerLinesAreLeft() {
        #expect(parseOutput("/p/a.c:1:2: error: x", with: TSCOutputParser()).unread.count == 1)
    }
}
