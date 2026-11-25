/**
    @file PackCodeGraph.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief How Aember's code graph reads Rust trees.
    @details
    Declarations, imports and closures of tree-sitter-rust. An impl block is named after the implementing type (its type field), not the trait in `impl Trait for Type`, so its methods are qualified by the type and don't collide with the trait's own declarations; that name is a use of the type, so it still counts as one.
*/

import Foundation
import AemberLanguageKit

// l10n-exempt-file: grammar node type names

/// @brief The pack's code-graph rules
enum PackCodeGraph {

    /// Rust's declarations
    static let rust = CodeGraphRules(
        symbols: [
            "const_item": .constant,
            "enum_item": .enumDeclaration,
            "field_declaration": .property,
            "function_item": .function,
            "function_signature_item": .method,
            "impl_item": .classDeclaration,
            "let_declaration": .variable,
            "macro_definition": .macro,
            "mod_item": .module,
            "struct_item": .structDeclaration,
            "trait_item": .protocolDeclaration,
        ],
        nameFields: ["impl_item": "type"],
        namesAreUses: ["impl_item"],
        imports: ["extern_crate_declaration", "use_declaration"],
        anonymousFunctions: ["closure_expression"]
    )
}
