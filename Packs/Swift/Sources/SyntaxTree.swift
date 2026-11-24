/**
    @file SyntaxTree.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Parsing text with tree-sitter, as much as the manifest editor
    needs.
    @details
    The pack compiles tree-sitter's runtime in (Grammar/runtime) beside
    its grammar, so it links nothing of Aember's but the SDK; this wraps
    the little of its C API SwiftPMManifestEditor uses. Text is parsed
    as UTF-16, so a node's byte offsets halve to NSString's.
*/

import Foundation
#if canImport(TreeSitterSwift)
import TreeSitterSwift
#endif

/// @brief Why a parser can't be used
enum SyntaxTreeError: Error {
    /// The grammar's ABI isn't one the runtime reads
    case incompatibleLanguage
}

/// @brief A tree-sitter parser
final class Parser {

    private let parser: OpaquePointer

    init() {
        parser = ts_parser_new()
    }

    deinit {
        ts_parser_delete(parser)
    }

    /// @brief Sets the grammar to parse with.
    /// @param language The grammar's TSLanguage
    /// @throws SyntaxTreeError.incompatibleLanguage
    func setLanguage(_ language: OpaquePointer) throws {
        guard ts_parser_set_language(parser, language) else {
            throw SyntaxTreeError.incompatibleLanguage
        }
    }

    /// @brief Parses text.
    /// @param text The text
    /// @return Its tree, or nil when parsing failed
    func parse(_ text: String) -> SyntaxTree? {
        let units = Array(text.utf16)
        let tree = units.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { base in
                base.withMemoryRebound(to: CChar.self, capacity: buffer.count * 2) {
                    ts_parser_parse_string_encoding(parser, nil, $0, UInt32(buffer.count * 2), TSInputEncodingUTF16LE)
                }
            } ?? ts_parser_parse_string_encoding(parser, nil, "", 0, TSInputEncodingUTF16LE)
        }
        return tree.map(SyntaxTree.init)
    }
}

/// @brief A parsed tree
final class SyntaxTree {

    fileprivate let tree: OpaquePointer

    fileprivate init(_ tree: OpaquePointer) {
        self.tree = tree
    }

    deinit {
        ts_tree_delete(tree)
    }

    /// The root node
    var rootNode: Node? {
        Node(ts_tree_root_node(tree), in: self)
    }
}

/// @brief A node of a parsed tree; it keeps its tree alive
struct Node {

    private let node: TSNode
    private let tree: SyntaxTree

    fileprivate init?(_ node: TSNode, in tree: SyntaxTree) {
        guard !ts_node_is_null(node) else {
            return nil
        }
        self.node = node
        self.tree = tree
    }

    /// The node's type ("call_expression", "ERROR")
    var nodeType: String? {
        ts_node_type(node).map { String(cString: $0) }
    }

    /// Whether the parser inserted the node to recover from an error
    var isMissing: Bool {
        ts_node_is_missing(node)
    }

    /// Whether it's a named node, rather than punctuation or a keyword
    var isNamed: Bool {
        ts_node_is_named(node)
    }

    /// How many children it has, named or not
    var childCount: Int {
        Int(ts_node_child_count(node))
    }

    /// @brief A child.
    /// @param index Its index
    /// @return The child, or nil past the last
    func child(at index: Int) -> Node? {
        guard index >= 0, index < childCount else {
            return nil
        }
        return Node(ts_node_child(node, UInt32(index)), in: tree)
    }

    /// Where it is in the text, in UTF-16 units
    var range: NSRange {
        let start = Int(ts_node_start_byte(node)) / 2
        return NSRange(location: start, length: Int(ts_node_end_byte(node)) / 2 - start)
    }
}
