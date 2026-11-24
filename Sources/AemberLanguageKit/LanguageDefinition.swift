/**
    @file LanguageDefinition.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief
    A language a pack defines: which files are in it, and how to parse and
    highlight them.
    @details
    A LanguageDefinition says which files are the language's (by
    extension, by name, by a name's start, by a shebang's interpreter),
    what the language servers call it, and optionally its tree-sitter
    grammar and queries. A language without a grammar, or without a
    highlights query, is highlighted with Aember's own definitions for
    it, where Aember has them.
*/

import Foundation

/// @brief A tree-sitter grammar, compiled into the pack.
/// @details
/// The function is the grammar's `tree_sitter_<name>()`, which returns
/// its `const TSLanguage *`. A pack links the grammar's parser.c (and
/// scanner.c) statically, so its symbols are the pack's own.
public struct Grammar: Sendable {

    /// Returns the grammar's TSLanguage
    public let language: @convention(c) () -> OpaquePointer

    /// The tree-sitter ABI version the grammar was generated for, when
    /// the pack knows it; Aember checks it against its tree-sitter's
    public let abiVersion: Int?

    /// @brief A grammar from its language function.
    /// @param language The grammar's tree_sitter_<name> function
    /// @param abiVersion Its tree-sitter ABI version, if known
    /// @return The grammar
    public init(_ language: @escaping @convention(c) () -> OpaquePointer, abiVersion: Int? = nil) {
        self.language = language
        self.abiVersion = abiVersion
    }
}

/// @brief A language's tree-sitter queries, as their source text.
public struct LanguageQueries: Hashable, Sendable {

    /// highlights.scm: names nodes with capture names Aember's themes
    /// color (@keyword, @string, @function, ...)
    public var highlights: String?

    /// injections.scm: other languages inside this one
    public var injections: String?

    /// locals.scm: scopes, definitions and references
    public var locals: String?

    /// folds.scm: what can be folded
    public var folds: String?

    /// @brief Queries from their sources; each is optional.
    /// @param highlights highlights.scm
    /// @param injections injections.scm
    /// @param locals locals.scm
    /// @param folds folds.scm
    /// @return The queries
    public init(highlights: String? = nil, injections: String? = nil, locals: String? = nil, folds: String? = nil) {
        self.highlights = highlights
        self.injections = injections
        self.locals = locals
        self.folds = folds
    }
}

/// @brief One language, as a pack defines it.
public struct LanguageDefinition: Sendable {

    /// The language's name in Aember, lowercase ("swift", "cpp",
    /// "tsx"): the name editors, themes and Aember's fallback
    /// definitions know it by
    public var id: String

    /// The name shown to the user ("C++")
    public var displayName: LocalizedText

    /// File extensions, without the dot, any case ("swift")
    public var extensions: [String]

    /// Whole file names, any case ("makefile", "dockerfile")
    public var fileNames: [String]

    /// Starts of file names, any case ("makefile.", "dockerfile.")
    public var fileNamePrefixes: [String]

    /// Interpreters in a shebang line, matched as the start of the
    /// interpreter's name, so "python" matches python3 ("python")
    public var shebangInterpreters: [String]

    /// The language servers' name for the language ("swift",
    /// "typescriptreact"); nil when no server serves it
    public var lspLanguageID: String?

    /// LSP names for particular extensions, where they differ from
    /// lspLanguageID ("mm": "objective-cpp")
    public var lspLanguageIDsByExtension: [String: String]

    /// What starts a line comment ("//")
    public var lineComment: String?

    /// What starts and ends a block comment ("/*", "*/")
    public var blockComment: (start: String, end: String)?

    /// The grammar; nil uses Aember's own for the language, if any
    public var grammar: Grammar?

    /// The grammar's queries; a missing highlights query uses Aember's
    /// own for the language, if any
    public var queries: LanguageQueries

    /// A language whose queries come before this one's, for grammars
    /// whose queries only add to another's (TypeScript's to
    /// JavaScript's)
    public var inheritsQueriesFrom: String?

    /// @brief A language.
    /// @param id Aember's name for it
    /// @param displayName The name shown to the user
    /// @param extensions File extensions, without the dot
    /// @param fileNames Whole file names
    /// @param fileNamePrefixes Starts of file names
    /// @param shebangInterpreters Interpreters in a shebang line
    /// @param lspLanguageID The language servers' name for it
    /// @param lspLanguageIDsByExtension LSP names for some extensions
    /// @param lineComment What starts a line comment
    /// @param blockComment What starts and ends a block comment
    /// @param grammar Its tree-sitter grammar
    /// @param queries The grammar's queries
    /// @param inheritsQueriesFrom A language whose queries come first
    /// @return The language
    public init(
        id: String,
        displayName: LocalizedText,
        extensions: [String] = [],
        fileNames: [String] = [],
        fileNamePrefixes: [String] = [],
        shebangInterpreters: [String] = [],
        lspLanguageID: String? = nil,
        lspLanguageIDsByExtension: [String: String] = [:],
        lineComment: String? = nil,
        blockComment: (start: String, end: String)? = nil,
        grammar: Grammar? = nil,
        queries: LanguageQueries = LanguageQueries(),
        inheritsQueriesFrom: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.extensions = extensions
        self.fileNames = fileNames
        self.fileNamePrefixes = fileNamePrefixes
        self.shebangInterpreters = shebangInterpreters
        self.lspLanguageID = lspLanguageID
        self.lspLanguageIDsByExtension = lspLanguageIDsByExtension
        self.lineComment = lineComment
        self.blockComment = blockComment
        self.grammar = grammar
        self.queries = queries
        self.inheritsQueriesFrom = inheritsQueriesFrom
    }

    /// @brief The LSP name for a file of this language.
    /// @param fileExtension The file's extension
    /// @return The name, or nil when no server serves the file
    public func lspLanguageID(forExtension fileExtension: String) -> String? {
        lspLanguageIDsByExtension[fileExtension.lowercased()] ?? lspLanguageID
    }
}
