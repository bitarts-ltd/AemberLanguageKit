/**
    @file SwiftCallShapeReaderTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Tests for SwiftCallShapeReader on trees tree-sitter-swift
    parses: calls by their labels and trailing closures, member calls,
    compound-name references and subscripts, and labels kept out of the
    uses.
*/

import Foundation
import Testing
import AemberLanguageKit
@testable import SwiftPack
#if canImport(TreeSitterSwift)
import TreeSitterSwift
#endif

struct SwiftCallShapeReaderTests {

    private let reader = SwiftCallShapeReader()

    /// @brief The calls in a text, read in document order, skipping
    /// those folded into an outer one, as Aember's walk does.
    private func calls(in source: String) throws -> [CallShape] {
        let parser = Parser()
        try parser.setLanguage(try #require(tree_sitter_swift()))
        let tree = try #require(parser.parse(source))
        let text = source as NSString
        var shapes: [CallShape] = []
        var folded = Set<NSRange>()
        func walk(_ node: Node) {
            if node.nodeType == "call_expression", !folded.contains(node.range), let shape = reader.callShape(of: PackSyntaxNode(node: node), in: text) {
                folded.formUnion(shape.foldedCalls)
                shapes.append(shape)
            }
            for i in 0..<node.childCount {
                if let child = node.child(at: i) {
                    walk(child)
                }
            }
        }
        walk(try #require(tree.rootNode))
        return shapes
    }

    @Test func callsByLabelsAndTrailingClosures() throws {
        let shapes = try calls(in: "f(x, at: y) { }\na.b.bar(named: 1)\n")
        #expect(shapes.map(\.name) == ["f", "bar"])
        #expect(shapes.map(\.shape) == ["_,at,{}", "named"])
    }

    @Test func referencesAndSubscriptsAreNotCounted() throws {
        let shapes = try calls(in: "let g = foo(_:in:)\nlet v = list[0]\n")
        #expect(shapes.allSatisfy { $0.name == nil })
    }

    @Test func labelsAreNotUses() throws {
        let source = "load(at: path)\n"
        let shape = try #require(try calls(in: source).first)
        let text = source as NSString
        let words = shape.labelLocations.map { text.substring(with: NSRange(location: $0, length: text.substring(from: $0).prefix { $0.isLetter }.utf16.count)) }
        #expect(Set(words) == ["load", "at"])
    }

    @Test func acceptsByLabels() {
        #expect(reader.accepts("at", signature: "(at url: URL) -> Data"))
        #expect(!reader.accepts("named", signature: "(at url: URL) -> Data"))
        #expect(reader.accepts("anything", signature: "not a signature"))
    }
}
