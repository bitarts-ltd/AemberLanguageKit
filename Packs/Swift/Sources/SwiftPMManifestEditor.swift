/**
    @file SwiftPMManifestEditor.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Takes a dependency out of a Package.swift's text
    @details
    SwiftPM has no remove-dependency, so Aember removes a Swift package
    itself: this finds, with the pack's Swift tree-sitter grammar (SyntaxTree), the
    .package(...) in Package(dependencies: [...]) whose url:, path: or
    id: is the dependency's, and (for Remove, not for a rule change)
    every .product(name:, package:) naming it in an array, plus a bare
    "Name" string or .byName(name:) in a target's dependencies when the
    name is the package's and no target of the manifest has it. Each is
    removed with its comma, and with its line when it was alone on it
    (a trailing // comment goes with it).

    It edits only what it can match literally: a manifest that builds
    the dependencies list in code (a variable, +, a function), a
    .product outside an array literal, or one tree-sitter can't parse
    gives nil, and the caller falls back to opening the manifest. The
    result is checked afterwards with dump-package (PackageChangeRunner).
*/

import Foundation
import AemberLanguageKit
#if canImport(TreeSitterSwift)
import TreeSitterSwift
#endif

/// @brief Removes a Swift dependency from Package.swift's text
enum SwiftPMManifestEditor {

    /// The calls that declare a target, whose dependencies may name a
    /// package's product by a bare string
    static let targetCallees: Set<String> = [
        ".target", ".executableTarget", ".testTarget", ".plugin", ".macro",
        ".systemLibrary", ".binaryTarget",
    ]

    /// @brief The manifest's text without a dependency.
    /// @param dependency The dependency, as dump-package gave it (its
    /// name is the package's identity, its location the URL, path or
    /// registry identity)
    /// @param manifest Package.swift's text
    /// @param folder The manifest's folder, for relative paths
    /// @param products Whether to remove the targets' uses of its
    /// products too (Remove), or only its declaration (a rule change,
    /// which adds it again)
    /// @return The new text, or nil if the dependency isn't written in
    /// a form this can edit
    static func removing(
        _ dependency: PackageDependency,
        from manifest: String,
        folder: URL,
        products: Bool
    ) -> String? {
        guard let ranges = removalRanges(of: dependency, in: manifest, folder: folder, products: products) else {
            return nil
        }
        return applying(ranges, to: manifest)
    }

    /// @brief The ranges to delete to remove a dependency.
    /// @param dependency The dependency
    /// @param manifest Package.swift's text
    /// @param folder The manifest's folder
    /// @param products Whether its products' uses go too
    /// @return The ranges, UTF-16, sorted and not overlapping; nil if
    /// the dependency isn't written in a form this can edit
    static func removalRanges(
        of dependency: PackageDependency,
        in manifest: String,
        folder: URL,
        products: Bool
    ) -> [NSRange]? {
        guard let tree = Tree(manifest), !tree.hasError,
              let package = tree.calls.first(where: { tree.callee(of: $0) == "Package" }),
              let list = tree.arguments(of: package).first(where: { $0.label == "dependencies" })?.value,
              tree.type(list) == "array_literal"
        else {
            return nil
        }
        let identity = dependency.name.lowercased()
        var names: Set<String> = [identity]
        var ranges: [NSRange] = []
        for element in tree.elements(of: list) where tree.callee(of: element) == ".package" {
            let arguments = tree.arguments(of: element)
            guard declares(dependency, arguments: arguments, tree: tree, folder: folder) else { continue }
            if let name = arguments.first(where: { $0.label == "name" }).flatMap({ tree.stringValue($0.value) }) {
                names.insert(name.lowercased())
            }
            ranges.append(tree.removalRange(of: element, in: list))
        }
        guard !ranges.isEmpty else { return nil }
        if products {
            guard let uses = productRanges(naming: names, tree: tree, package: package) else { return nil }
            ranges += uses
        }
        return merged(ranges)
    }

    /// @brief Whether a .package(...) call declares a dependency.
    /// @param dependency The dependency
    /// @param arguments The call's arguments
    /// @param tree The parsed manifest
    /// @param folder The manifest's folder
    /// @return true if its url:, path: or id: is the dependency's
    private static func declares(
        _ dependency: PackageDependency,
        arguments: [Tree.Argument],
        tree: Tree,
        folder: URL
    ) -> Bool {
        let identity = dependency.name.lowercased()
        for argument in arguments {
            guard let value = tree.stringValue(argument.value) else { continue }
            switch argument.label {
            case "url":
                if value == dependency.location || SwiftPMBackend.identity(ofLocation: value) == identity {
                    return true
                }
            case "path":
                let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : folder.appendingPathComponent(value)
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                let target = dependency.location.map {
                    URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
                }
                if path == target || SwiftPMBackend.identity(ofLocation: value) == identity {
                    return true
                }
            case "id":
                if value.lowercased() == identity {
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    /// @brief The uses of a package's products to remove: .product
    /// calls naming it in arrays, and bare names in targets'
    /// dependencies.
    /// @param names The package's identity and name, lower cased
    /// @param tree The parsed manifest
    /// @param package The Package(...) call
    /// @return The ranges, or nil if a .product naming it isn't an
    /// array's element
    private static func productRanges(naming names: Set<String>, tree: Tree, package: Node) -> [NSRange]? {
        var ranges: [NSRange] = []
        var removed = 0

        // Targets of the manifest, whose names a bare string may mean
        var targetNames = Set<String>()
        if let targets = tree.arguments(of: package).first(where: { $0.label == "targets" })?.value,
           tree.type(targets) == "array_literal" {
            for target in tree.elements(of: targets) {
                if let name = tree.arguments(of: target).first(where: { $0.label == "name" })
                    .flatMap({ tree.stringValue($0.value) }) {
                    targetNames.insert(name.lowercased())
                }
            }
        }

        for array in tree.nodes(ofType: "array_literal") {
            for element in tree.elements(of: array) {
                let callee = tree.callee(of: element)
                if callee == ".product" {
                    let named = tree.arguments(of: element).first { $0.label == "package" }
                        .flatMap { tree.stringValue($0.value) }
                    if let named, names.contains(named.lowercased()) {
                        ranges.append(tree.removalRange(of: element, in: array))
                        removed += 1
                    }
                }
            }
        }
        let all = tree.calls.filter { call in
            guard tree.callee(of: call) == ".product" else { return false }
            let named = tree.arguments(of: call).first { $0.label == "package" }.flatMap { tree.stringValue($0.value) }
            return named.map { names.contains($0.lowercased()) } ?? false
        }
        guard all.count == removed else { return nil }

        // Bare names in targets' dependencies
        for call in tree.calls where targetCallees.contains(tree.callee(of: call) ?? "") {
            guard let list = tree.arguments(of: call).first(where: { $0.label == "dependencies" })?.value,
                  tree.type(list) == "array_literal"
            else {
                continue
            }
            for element in tree.elements(of: list) {
                var name: String?
                if tree.type(element) == "line_string_literal" {
                    name = tree.stringValue(element)
                } else if tree.callee(of: element) == ".byName" {
                    name = tree.arguments(of: element).first { $0.label == "name" }
                        .flatMap { tree.stringValue($0.value) }
                }
                guard let name, names.contains(name.lowercased()), !targetNames.contains(name.lowercased()) else {
                    continue
                }
                ranges.append(tree.removalRange(of: element, in: list))
            }
        }
        return ranges
    }

    /// @brief Ranges sorted, overlapping or touching ones joined.
    /// @param ranges The ranges
    /// @return The joined ranges, in order
    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// @brief A text with ranges deleted.
    /// @param ranges The ranges, UTF-16, not overlapping
    /// @param text The text
    /// @return The text without them
    static func applying(_ ranges: [NSRange], to text: String) -> String {
        let result = NSMutableString(string: text)
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            result.deleteCharacters(in: range)
        }
        return result as String
    }
}

// MARK: - The Syntax Tree

extension SwiftPMManifestEditor {

    /// @brief A parsed Package.swift and what the editor asks of it
    struct Tree {

        /// One argument of a call: its label, if any, and its value
        struct Argument {
            let label: String?
            let value: Node
        }

        /// The manifest's text
        let text: NSString

        /// The root node
        let root: Node

        /// Every call in the manifest, in order
        let calls: [Node]

        /// Whether tree-sitter found a syntax error
        let hasError: Bool

        /// The node types that are comments
        private static let commentTypes: Set<String> = ["comment", "multiline_comment"]

        /// @brief Parses a manifest.
        /// @param manifest The text
        /// @return nil if the Swift grammar isn't available
        init?(_ manifest: String) {
            guard let language = tree_sitter_swift() else { return nil }
            let parser = Parser()
            guard (try? parser.setLanguage(language)) != nil,
                  let tree = parser.parse(manifest),
                  let root = tree.rootNode
            else {
                return nil
            }
            text = manifest as NSString
            self.root = root
            var calls: [Node] = []
            var hasError = false
            func walk(_ node: Node) {
                let type = node.nodeType ?? ""
                if type == "ERROR" || node.isMissing {
                    hasError = true
                }
                if type == "call_expression" {
                    calls.append(node)
                }
                for index in 0..<node.childCount {
                    if let child = node.child(at: index) {
                        walk(child)
                    }
                }
            }
            walk(root)
            self.calls = calls
            self.hasError = hasError
        }

        /// @brief A node's type.
        func type(_ node: Node) -> String {
            node.nodeType ?? ""
        }

        /// @brief A node's text.
        func string(_ node: Node) -> String {
            text.substring(with: node.range)
        }

        /// @brief A node's children, unnamed ones (punctuation) too.
        func children(_ node: Node) -> [Node] {
            (0..<node.childCount).compactMap { node.child(at: $0) }
        }

        /// @brief Every node of a type, in order.
        func nodes(ofType wanted: String) -> [Node] {
            var found: [Node] = []
            func walk(_ node: Node) {
                if type(node) == wanted {
                    found.append(node)
                }
                children(node).forEach(walk)
            }
            walk(root)
            return found
        }

        /// @brief The name a call calls: "Package" for Package(...),
        /// ".package" for .package(...) and
        /// Package.Dependency.package(...).
        /// @param node A node
        /// @return The name, or nil if the node isn't a call
        func callee(of node: Node) -> String? {
            guard type(node) == "call_expression", let callee = node.child(at: 0) else { return nil }
            switch type(callee) {
            case "simple_identifier":
                return string(callee)
            case "prefix_expression":
                guard let name = children(callee).last(where: { type($0) == "simple_identifier" }) else {
                    return nil
                }
                return "." + string(name)
            case "navigation_expression":
                guard let suffix = children(callee).last(where: { type($0) == "navigation_suffix" }),
                      let name = children(suffix).last(where: { type($0) == "simple_identifier" })
                else {
                    return nil
                }
                return "." + string(name)
            default:
                return nil
            }
        }

        /// @brief A call's arguments, in order.
        /// @param call A call_expression
        /// @return Its arguments in parentheses; none for other nodes
        func arguments(of call: Node) -> [Argument] {
            guard type(call) == "call_expression",
                  let suffix = children(call).first(where: { type($0) == "call_suffix" }),
                  let list = children(suffix).first(where: { type($0) == "value_arguments" })
            else {
                return []
            }
            return children(list).filter { type($0) == "value_argument" }.compactMap { argument in
                let parts = children(argument).filter(\.isNamed)
                let label = parts.first { type($0) == "value_argument_label" }
                guard let value = parts.last(where: { type($0) != "value_argument_label" }) else { return nil }
                return Argument(label: label.map(string), value: value)
            }
        }

        /// @brief An array literal's elements, comments left out.
        func elements(of array: Node) -> [Node] {
            children(array).filter { $0.isNamed && !Self.commentTypes.contains(type($0)) }
        }

        /// @brief A string literal's text, when it is one plain string.
        /// @param node A node
        /// @return The text, or nil for anything else, an interpolated
        /// or escaped string included
        func stringValue(_ node: Node) -> String? {
            guard type(node) == "line_string_literal" else { return nil }
            var value = ""
            for part in children(node) where part.isNamed {
                guard type(part) == "line_str_text" else { return nil }
                value += string(part)
            }
            return value
        }

        /// @brief The range that removes an element from an array.
        /// @detail
        /// The element with the comma after it, else (the last element,
        /// written without a trailing comma) the comma before it. When
        /// the element starts its line, a // comment after it on its
        /// last line goes too, and when nothing else is left on its
        /// lines, the lines go.
        /// @param element The element
        /// @param array The array literal
        /// @return The range, UTF-16
        func removalRange(of element: Node, in array: Node) -> NSRange {
            let all = children(array).filter { !Self.commentTypes.contains(type($0)) }
            var start = element.range.location
            var end = NSMaxRange(element.range)
            var tookComma = false
            if let index = all.firstIndex(where: { $0.range == element.range }) {
                if index + 1 < all.count, type(all[index + 1]) == "," {
                    end = NSMaxRange(all[index + 1].range)
                    tookComma = true
                } else if index > 0, type(all[index - 1]) == "," {
                    start = all[index - 1].range.location
                }
            }
            let elementLineStart = lineStart(of: element.range.location)
            let startsLine = isBlank(NSRange(location: elementLineStart, length: element.range.location - elementLineStart))
            let lineEnd = lineEnd(of: end)
            let rest = text.substring(with: NSRange(location: end, length: lineEnd - end))
                .trimmingCharacters(in: .whitespaces)
            if startsLine && (rest.isEmpty || rest.hasPrefix("//")) {
                end = lineEnd
                let startLine = lineStart(of: start)
                if isBlank(NSRange(location: startLine, length: start - startLine)) {
                    start = startLine
                    if end < text.length {
                        end += 1
                    }
                }
            } else if tookComma {
                // The space after the comma, before the next element
                while end < lineEnd, text.character(at: end) == 0x20 || text.character(at: end) == 0x09 {
                    end += 1
                }
            }
            return NSRange(location: start, length: end - start)
        }

        /// @brief Where the line holding a position starts.
        private func lineStart(of position: Int) -> Int {
            let found = text.range(
                of: "\n",
                options: .backwards,
                range: NSRange(location: 0, length: position)
            )
            return found.location == NSNotFound ? 0 : NSMaxRange(found)
        }

        /// @brief Where the line holding a position ends, before its
        /// line break.
        private func lineEnd(of position: Int) -> Int {
            let found = text.range(
                of: "\n",
                range: NSRange(location: position, length: text.length - position)
            )
            return found.location == NSNotFound ? text.length : found.location
        }

        /// @brief Whether a range holds only spaces and tabs.
        private func isBlank(_ range: NSRange) -> Bool {
            text.substring(with: range).allSatisfy { $0 == " " || $0 == "\t" }
        }
    }
}
