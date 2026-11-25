/**
    @file PackCodeGraph.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief How Aember's code graph reads Python trees.
    @details
    Declarations and imports of tree-sitter-python.
*/

import Foundation
import AemberLanguageKit

// l10n-exempt-file: grammar node type names

/// @brief The pack's code-graph rules
enum PackCodeGraph {

    /// Python's declarations
    static let python = CodeGraphRules(
        symbols: [
            "class_definition": .classDeclaration,
            "function_definition": .function,
        ],
        imports: ["import_from_statement", "import_statement"],
        anonymousFunctions: []
    )
}
