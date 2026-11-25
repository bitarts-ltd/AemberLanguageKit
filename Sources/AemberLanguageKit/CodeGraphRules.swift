/**
    @file CodeGraphRules.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief How Aember's code graph reads a language's syntax tree.
    @details
    Aember indexes every project's declarations, imports and name
    uses from tree-sitter trees, for its symbol search, outline and
    the codegraph tools agents use. The walk is Aember's; a language
    says which of its grammar's node types are declarations and of
    what kind, which are imports and anonymous functions, and the few
    places its grammar names things unusually. A language without
    rules is read with Aember's own table, which knows the common
    node names of many grammars.

    A language whose calls name their arguments, as Swift's do, can
    also give a CallShapeReader, so a function is only counted as
    used by calls whose labels it accepts (file(at:) doesn't keep
    file(named:) alive).
*/

import Foundation

/// @brief What kind of symbol a declaration is.
public enum CodeSymbolKind: String, CaseIterable, Sendable {
    case function
    case method
    case initializer
    case property
    case variable
    case constant
    case classDeclaration = "class"
    case structDeclaration = "struct"
    case enumDeclaration = "enum"
    case extensionDeclaration = "extension"
    case enumCase = "enum_case"
    case protocolDeclaration = "protocol"
    case interfaceDeclaration = "interface"
    case typeAlias = "typealias"
    case module
    case namespace
    case macro
    case other
}

/// @brief How Aember's code graph reads one language's trees.
/// @details
/// Every name here is a node type of the language's grammar. A
/// function declared directly in a class, struct, enum, extension,
/// protocol or interface is a method in every language, and
/// variables inside functions are locals, which the graph leaves out.
public struct CodeGraphRules: Sendable {

    /// Declaration node types and the kind of symbol each declares
    /// ("function_item": .function). A declaration is named by its
    /// first identifier, unless nameFields or nameChildTypes say
    /// otherwise.
    public var symbols: [String: CodeSymbolKind]

    /// Declarations whose kind a keyword child decides: node type,
    /// then the keyword's node type and its kind (tree-sitter-swift's
    /// "class_declaration" is a class, struct, enum, actor or
    /// extension by its keyword)
    public var kindKeywords: [String: [String: CodeSymbolKind]]

    /// Declarations named by a field, not their first identifier:
    /// node type and field ("impl_item": "type", so `impl Trait for
    /// Type` is named Type)
    public var nameFields: [String: String]

    /// Declarations named by a child of a node type, such as a
    /// keyword ("init_declaration": "init")
    public var nameChildTypes: [String: String]

    /// Declarations whose name is a use of another symbol, still
    /// counted as a use (a Rust impl's type)
    public var namesAreUses: Set<String>

    /// Import node types; their text is read as an import
    public var imports: Set<String>

    /// Anonymous function node types: named only by a `name` field,
    /// and their variables are locals
    public var anonymousFunctions: Set<String>

    /// Declarator node types that name their declaration's own
    /// variable when first in it, by the declarations they appear in
    /// ("variable_declarator": ["lexical_declaration"], so `const x =
    /// 1` is one symbol, not two)
    public var firstDeclarators: [String: Set<String>]

    /// Modifiers that keep a declaration to its own file (Swift's
    /// "private", "fileprivate"), so only uses in that file keep it
    /// alive
    public var fileScopedModifiers: Set<String>

    /// Reads calls by their argument labels, for languages whose
    /// argument labels choose the function called
    public var callShapes: (any CallShapeReader)?

    /// @brief A language's rules.
    /// @param symbols Declaration node types and their kinds
    /// @param kindKeywords Declarations whose keyword child decides
    ///     their kind
    /// @param nameFields Declarations named by a field
    /// @param nameChildTypes Declarations named by a child's type
    /// @param namesAreUses Declarations whose name is a use
    /// @param imports Import node types
    /// @param anonymousFunctions Anonymous function node types
    /// @param firstDeclarators Declarators that are their
    ///     declaration's own variable when first
    /// @param fileScopedModifiers Modifiers keeping a declaration to
    ///     its file
    /// @param callShapes Reads calls by their argument labels
    /// @return The rules
    public init(symbols: [String: CodeSymbolKind], kindKeywords: [String: [String: CodeSymbolKind]] = [:], nameFields: [String: String] = [:], nameChildTypes: [String: String] = [:], namesAreUses: Set<String> = [], imports: Set<String> = [], anonymousFunctions: Set<String> = [], firstDeclarators: [String: Set<String>] = [:], fileScopedModifiers: Set<String> = [], callShapes: (any CallShapeReader)? = nil) {
        self.symbols = symbols
        self.kindKeywords = kindKeywords
        self.nameFields = nameFields
        self.nameChildTypes = nameChildTypes
        self.namesAreUses = namesAreUses
        self.imports = imports
        self.anonymousFunctions = anonymousFunctions
        self.firstDeclarators = firstDeclarators
        self.fileScopedModifiers = fileScopedModifiers
        self.callShapes = callShapes
    }
}

// MARK: - Call shapes

/// @brief A node of a syntax tree, as Aember hands it to a pack.
/// @details
/// Ranges are UTF-16 offsets into the file's text, as NSString
/// counts them.
public protocol SyntaxNode {

    /// The node's type in its grammar ("call_expression"), or a
    /// keyword's text for an anonymous node ("init", "[")
    var nodeType: String? { get }

    /// Its range in the file's text
    var range: NSRange { get }

    /// How many children it has, named and anonymous
    var childCount: Int { get }

    /// @brief A child.
    /// @param index The child's index
    /// @return The child, or nil
    func child(at index: Int) -> (any SyntaxNode)?

    /// @brief The field a child is in ("name").
    /// @param index The child's index
    /// @return The field's name, or nil
    func fieldName(forChildAt index: Int) -> String?
}

extension SyntaxNode {

    /// The last child, if any
    public var lastChild: (any SyntaxNode)? {
        childCount > 0 ? child(at: childCount - 1) : nil
    }
}

/// @brief One call, read by its argument labels.
public struct CallShape: Equatable, Sendable {

    /// The name called, or nil when the node isn't a call to a name
    /// that can be counted (a reference such as foo(_:in:), a
    /// subscript, a call of a call's result)
    public var name: String?

    /// The call's shape: a key the reader's accepts(_:signature:)
    /// understands
    public var shape: String

    /// Where names start that are part of the call and not uses
    /// (the called name, argument labels), as UTF-16 offsets
    public var labelLocations: [Int]

    /// Nested calls this call took in (trailing closures parsed as a
    /// call of the call), which aren't read again
    public var foldedCalls: [NSRange]

    /// @brief A call.
    /// @param name The name called
    /// @param shape Its shape
    /// @param labelLocations Where its labels and called name start
    /// @param foldedCalls Nested calls it took in
    /// @return The call
    public init(name: String?, shape: String, labelLocations: [Int] = [], foldedCalls: [NSRange] = []) {
        self.name = name
        self.shape = shape
        self.labelLocations = labelLocations
        self.foldedCalls = foldedCalls
    }
}

/// @brief Reads a language's calls by their argument labels, and
/// says which calls a declaration accepts.
public protocol CallShapeReader: Sendable {

    /// The node types that are calls
    var callNodeTypes: Set<String> { get }

    /// @brief Reads a call.
    /// @param node A node of one of callNodeTypes
    /// @param text The file's text
    /// @return The call, or nil when the node isn't one after all
    func callShape(of node: any SyntaxNode, in text: NSString) -> CallShape?

    /// @brief Whether a call of this shape could call a declaration.
    /// @details
    /// Errs toward yes when the signature can't be read.
    /// @param shape A CallShape's shape
    /// @param signature The declaration's signature, as the code
    ///     graph keeps it ("(at url: URL) -> Data")
    /// @return True when it could
    func accepts(_ shape: String, signature: String) -> Bool
}
