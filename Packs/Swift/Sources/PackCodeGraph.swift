/**
    @file PackCodeGraph.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief How Aember's code graph reads Swift trees.
    @details
    Declarations, imports and closures of tree-sitter-swift. Its class_declaration is a class, actor, struct, enum or extension by its keyword; an initializer is named by its init keyword, not its first parameter. private and fileprivate keep a declaration to its file, and calls are read by their argument labels (SwiftCallShapeReader), so a function only counts as used by calls whose labels it accepts.
*/

import Foundation
import AemberLanguageKit

// l10n-exempt-file: grammar node type names

/// @brief The pack's code-graph rules
enum PackCodeGraph {

    /// Swift's declarations
    static let swift = CodeGraphRules(
        symbols: [
            "class_declaration": .classDeclaration,
            "enum_entry": .enumCase,
            "function_declaration": .function,
            "init_declaration": .initializer,
            "macro_declaration": .macro,
            "macro_definition": .macro,
            "property_declaration": .property,
            "protocol_declaration": .protocolDeclaration,
            "protocol_function_declaration": .method,
            "protocol_property_declaration": .property,
            "typealias_declaration": .typeAlias,
        ],
        kindKeywords: ["class_declaration": ["class": .classDeclaration, "actor": .classDeclaration, "struct": .structDeclaration, "enum": .enumDeclaration, "extension": .extensionDeclaration]],
        nameChildTypes: ["init_declaration": "init"],
        imports: ["import_declaration"],
        anonymousFunctions: ["lambda_literal"],
        fileScopedModifiers: ["fileprivate", "private"],
        callShapes: SwiftCallShapeReader()
    )
}
