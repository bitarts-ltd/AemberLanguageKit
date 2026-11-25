/**
    @file PackCodeGraph.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief How Aember's code graph reads C and C++ trees.
    @details
    Declarations and includes of tree-sitter-c and tree-sitter-cpp.
*/

import Foundation
import AemberLanguageKit

// l10n-exempt-file: grammar node type names

/// @brief The pack's code-graph rules
enum PackCodeGraph {

    /// C's declarations
    static let c = CodeGraphRules(
        symbols: [
            "enum_specifier": .enumDeclaration,
            "enumerator": .enumCase,
            "field_declaration": .property,
            "function_definition": .function,
            "struct_specifier": .structDeclaration,
        ],
        imports: ["preproc_include"],
        anonymousFunctions: []
    )

    /// C++'s declarations
    static let cpp = CodeGraphRules(
        symbols: [
            "class_specifier": .classDeclaration,
            "enum_specifier": .enumDeclaration,
            "enumerator": .enumCase,
            "field_declaration": .property,
            "function_definition": .function,
            "lambda_expression": .function,
            "module_declaration": .module,
            "namespace_definition": .namespace,
            "struct_specifier": .structDeclaration,
        ],
        imports: ["import_declaration", "preproc_include"],
        anonymousFunctions: ["lambda_expression"]
    )
}
