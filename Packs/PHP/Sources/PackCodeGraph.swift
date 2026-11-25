/**
    @file PackCodeGraph.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief How Aember's code graph reads PHP trees.
    @details
    Declarations, imports and closures of tree-sitter-php's php_only grammar.
*/

import Foundation
import AemberLanguageKit

// l10n-exempt-file: grammar node type names

/// @brief The pack's code-graph rules
enum PackCodeGraph {

    /// PHP's declarations
    static let php = CodeGraphRules(
        symbols: [
            "arrow_function": .function,
            "class_declaration": .classDeclaration,
            "const_declaration": .constant,
            "enum_case": .enumCase,
            "enum_declaration": .enumDeclaration,
            "function_definition": .function,
            "interface_declaration": .interfaceDeclaration,
            "method_declaration": .method,
            "namespace_definition": .namespace,
            "property_declaration": .property,
        ],
        imports: ["require_expression", "use_declaration"],
        anonymousFunctions: ["anonymous_function", "arrow_function"]
    )
}
