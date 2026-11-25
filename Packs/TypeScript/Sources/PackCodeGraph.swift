/**
    @file PackCodeGraph.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief How Aember's code graph reads JavaScript, TypeScript and TSX trees.
    @details
    Declarations, imports and anonymous functions of the three grammars. A declaration (`const x = 1`) names its first declarator's variable, which isn't a second symbol.
*/

import Foundation
import AemberLanguageKit

// l10n-exempt-file: grammar node type names

/// @brief The pack's code-graph rules
enum PackCodeGraph {

    /// JavaScript's declarations
    static let javascript = CodeGraphRules(
        symbols: [
            "arrow_function": .function,
            "class_declaration": .classDeclaration,
            "function_declaration": .function,
            "lexical_declaration": .variable,
            "method_definition": .method,
            "variable_declaration": .variable,
            "variable_declarator": .variable,
        ],
        imports: ["import_statement"],
        anonymousFunctions: ["arrow_function", "function_expression", "generator_function"],
        firstDeclarators: ["variable_declarator": ["lexical_declaration", "variable_declaration"]]
    )

    /// TypeScript's declarations
    static let typescript = CodeGraphRules(
        symbols: [
            "arrow_function": .function,
            "class_declaration": .classDeclaration,
            "enum_declaration": .enumDeclaration,
            "function_declaration": .function,
            "interface_declaration": .interfaceDeclaration,
            "lexical_declaration": .variable,
            "method_definition": .method,
            "type_alias_declaration": .typeAlias,
            "variable_declaration": .variable,
            "variable_declarator": .variable,
        ],
        imports: ["import_statement"],
        anonymousFunctions: ["arrow_function", "function_expression", "generator_function"],
        firstDeclarators: ["variable_declarator": ["lexical_declaration", "variable_declaration"]]
    )

    /// TSX's declarations
    static let tsx = CodeGraphRules(
        symbols: [
            "arrow_function": .function,
            "class_declaration": .classDeclaration,
            "enum_declaration": .enumDeclaration,
            "function_declaration": .function,
            "interface_declaration": .interfaceDeclaration,
            "lexical_declaration": .variable,
            "method_definition": .method,
            "type_alias_declaration": .typeAlias,
            "variable_declaration": .variable,
            "variable_declarator": .variable,
        ],
        imports: ["import_statement"],
        anonymousFunctions: ["arrow_function", "function_expression", "generator_function"],
        firstDeclarators: ["variable_declarator": ["lexical_declaration", "variable_declaration"]]
    )
}
