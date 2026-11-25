/**
    @file SwiftCallShape.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Matches Swift call sites to function signatures by labels.
    @details
    A Swift call names its function by base name and argument labels
    together: file(at: x) can't call func file(named:). Dead code
    detection uses this to tell same-named functions apart. Calls are
    recorded as a shape key (their labels and trailing closures), and
    a function counts as called when some call's shape could bind to
    its parameters, allowing for defaulted and variadic parameters and
    trailing closures. Matching errs toward a match whenever a
    signature can't be read.

    SwiftCallShapeReader is the pack's CallShapeReader: it reads a
    call_expression of tree-sitter-swift into its called name and
    shape, and keeps its argument labels out of the name uses Aember
    counts.
*/

import Foundation
import AemberLanguageKit

/// @brief Argument label shapes of Swift calls, and whether a
/// function's parameters accept them.
enum SwiftCallShape {

    /// @brief One parameter of a Swift function signature.
    struct Parameter: Equatable {
        /// Argument label, or "_" if the argument is unlabeled.
        let label: String
        /// Whether the parameter has a default value.
        let hasDefault: Bool
        /// Whether the parameter is variadic (Type...).
        let isVariadic: Bool
        /// Whether the parameter's type is a function type.
        let isClosure: Bool
    }

    /// @brief Builds a call's shape key.
    /// @details
    /// Each argument contributes its label, or "_" if it has
    /// none; each trailing closure contributes "{}", after its
    /// label if it has one. Entries are joined with commas:
    /// f(x, at: y) { } is "_,at,{}", and f() is "".
    /// @param labels The call's entries, in order.
    /// @return The shape key.
    static func key(_ labels: [String]) -> String {
        return labels.joined(separator: ",")
    }

    /// @brief Reads the parameters from a function signature.
    /// @details
    /// Takes the first parenthesized list in a signature like
    /// "(_ a: Int, with b: String = \"\") -> Bool". A
    /// parameter's first name is its argument label; a lone
    /// name is both label and parameter name.
    /// @param signature The stored signature.
    /// @return The parameters, or nil if the signature has no
    ///   parameter list or one that can't be read.
    static func parameters(of signature: String) -> [Parameter]? {
        let chars = Array(signature)
        guard let open = chars.firstIndex(of: "("),
              let close = matchingClose(in: chars, from: open)
        else { return nil }
        let list = chars[(open + 1)..<close]
        if String(list).trimmingCharacters(in: .whitespaces).isEmpty {
            return []
        }
        var result: [Parameter] = []
        for part in split(list, on: ",") {
            guard let param = parameter(
                from: String(part).trimmingCharacters(in: .whitespaces)
            ) else { return nil }
            result.append(param)
        }
        return result
    }

    /// @brief Whether a call of some shape could call a function
    /// with these parameters.
    /// @details
    /// Labeled and unlabeled arguments bind to parameters in
    /// order; a parameter with a default, or a variadic one, may
    /// be skipped, and unlabeled arguments after a variadic
    /// argument join it. The first trailing closure binds to the
    /// next parameter of function type it can reach by skipping
    /// defaulted parameters (or, failing that, the next one),
    /// and labeled trailing closures bind by label. Parameters
    /// left over must have defaults.
    /// @param key The call's shape key (see key(_:)).
    /// @param parameters The function's parameters.
    /// @return True if the call could bind to the parameters.
    static func accepts(
        _ key: String, parameters: [Parameter]
    ) -> Bool {
        let entries = key.isEmpty
            ? [] : key.components(separatedBy: ",")
        var next = 0
        var variadic: Int?

        // Binds a label to the next parameter that takes it,
        // skipping parameters that may be left out.
        func bind(_ label: String) -> Bool {
            if label == "_", let v = variadic, v == next - 1 {
                return true
            }
            while next < parameters.count {
                let param = parameters[next]
                next += 1
                if param.label == label {
                    variadic = param.isVariadic ? next - 1 : nil
                    return true
                }
                if !param.hasDefault && !param.isVariadic {
                    return false
                }
            }
            return false
        }

        var sawTrailing = false
        for entry in entries {
            guard entry.hasSuffix("{}") else {
                guard bind(entry) else { return false }
                continue
            }
            let label = String(entry.dropLast(2))
            if !label.isEmpty, sawTrailing {
                guard bind(label) else { return false }
                continue
            }
            sawTrailing = true
            variadic = nil
            var reachable = next
            var target: Int?
            while reachable < parameters.count {
                if parameters[reachable].isClosure {
                    target = reachable
                    break
                }
                let param = parameters[reachable]
                guard param.hasDefault || param.isVariadic
                else { break }
                reachable += 1
            }
            guard let bound = target
                ?? (next < parameters.count ? next : nil)
            else { return false }
            next = bound + 1
        }

        return parameters[min(next, parameters.count)...]
            .allSatisfy { $0.hasDefault || $0.isVariadic }
    }

    // MARK: - Private Helpers

    /// @brief Reads one parameter from its text.
    /// @param text Text like "_ a: Int = 0".
    /// @return The parameter, or nil if it has no ":".
    private static func parameter(from text: String) -> Parameter? {
        let chars = Array(text)
        guard let colon = split(chars[...], on: ":").first.map({
            $0.endIndex
        }), colon < chars.count else { return nil }
        let names = String(chars[..<colon])
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { $0.trimmingCharacters(in: backtick) }
        guard let label = names.first else { return nil }

        let rest = chars[(colon + 1)...]
        let typeAndDefault = split(rest, on: "=")
        let type = String(typeAndDefault.first ?? rest)
            .trimmingCharacters(in: .whitespaces)
        return Parameter(
            label: label,
            hasDefault: typeAndDefault.count > 1,
            isVariadic: type.hasSuffix("..."),
            isClosure: type.contains("->")
        )
    }

    /// @brief Finds the bracket closing the one at an index.
    /// @param chars The text.
    /// @param open Index of an opening bracket.
    /// @return Index of its closing bracket, or nil.
    private static func matchingClose(
        in chars: [Character], from open: Int
    ) -> Int? {
        var depth = 0
        var inString = false
        var i = open
        while i < chars.count {
            let c = chars[i]
            if inString {
                if c == "\\" {
                    i += 1
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "\"" {
                inString = true
            } else if "([{".contains(c) {
                depth += 1
            } else if ")]}".contains(c) {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    /// @brief Splits text on a separator outside brackets and
    /// string literals.
    /// @details
    /// Angle brackets nest too, except in "->", so that commas
    /// in generic arguments don't split.
    /// @param chars The text.
    /// @param separator The separator character.
    /// @return The parts, without the separators.
    private static func split(
        _ chars: ArraySlice<Character>, on separator: Character
    ) -> [ArraySlice<Character>] {
        var parts: [ArraySlice<Character>] = []
        var depth = 0
        var inString = false
        var start = chars.startIndex
        var i = chars.startIndex
        while i < chars.endIndex {
            let c = chars[i]
            if inString {
                if c == "\\" {
                    i += 1
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "\"" {
                inString = true
            } else if "([{<".contains(c) {
                depth += 1
            } else if ")]}".contains(c) {
                depth -= 1
            } else if c == ">",
                      i == chars.startIndex || chars[i - 1] != "-" {
                depth -= 1
            } else if c == separator, depth == 0 {
                parts.append(chars[start..<i])
                start = i + 1
            }
            i += 1
        }
        parts.append(chars[start..<min(i, chars.endIndex)])
        return parts
    }

    /// @brief Character set for stripping escaped identifiers.
    private static let backtick = CharacterSet(charactersIn: "`")
}

/// @brief Reads Swift calls for Aember's code graph.
struct SwiftCallShapeReader: CallShapeReader {

    let callNodeTypes: Set<String> = ["call_expression"]

    /// @brief Reads a call by its argument labels.
    /// @details
    /// A compound name such as foo(_:in:) is a reference, not a call:
    /// its base name stays a plain usage, as do subscripted names
    /// (tree-sitter-swift parses a[i] as a call). Calls whose callee
    /// isn't a name (foo()(), ...) are left to the plain usage count.
    /// In some contexts (let x = f(a) { ... }) the grammar parses
    /// trailing closures as a call of the call; their suffix is folded
    /// into the inner call's, which then isn't read on its own.
    /// @param node A call_expression node
    /// @param text The file's text
    /// @return The call; its name is nil when it can't be counted
    func callShape(of node: any SyntaxNode, in text: NSString) -> CallShape? {
        guard node.childCount >= 2,
              var callee = node.child(at: 0),
              let suffix = node.child(at: node.childCount - 1),
              suffix.nodeType == "call_suffix" else { return nil }

        // Fold trailing-closure-only suffixes into the call they
        // follow
        var shape = CallShape(name: nil, shape: "")
        var suffixes = [suffix]
        while callee.nodeType == "call_expression",
              suffixes[0].child(at: 0)?.nodeType != "value_arguments",
              callee.childCount >= 2,
              let inner = callee.child(at: callee.childCount - 1),
              inner.nodeType == "call_suffix",
              let innerCallee = callee.child(at: 0) {
            shape.foldedCalls.append(callee.range)
            suffixes.insert(inner, at: 0)
            callee = innerCallee
        }

        var labels: [String] = []
        var isReference = false
        for suffix in suffixes {
            guard let entries = suffixLabels(suffix, text: text, shape: &shape, isReference: &isReference) else {
                return shape
            }
            labels += entries
        }

        guard !isReference,
              let nameNode = calleeName(callee),
              let name = Self.identifierText(nameNode, text: text),
              !name.isEmpty else { return shape }
        shape.labelLocations.append(nameNode.range.location)
        shape.name = name
        shape.shape = SwiftCallShape.key(labels)
        return shape
    }

    /// @brief Whether a call of a shape could call a function.
    /// @details
    /// A function whose signature can't be read is taken to be called
    /// by any call to its name.
    /// @param shape A call's shape key
    /// @param signature The function's signature
    /// @return True if the call could call it
    func accepts(_ shape: String, signature: String) -> Bool {
        guard let parameters = SwiftCallShape.parameters(of: signature) else {
            return true
        }
        return SwiftCallShape.accepts(shape, parameters: parameters)
    }

    /// @brief Gets the shape entries of one call suffix, keeping its
    /// labels out of the usage counts.
    /// @param suffix A call_suffix node
    /// @param text The file's text
    /// @param shape Collects the labels' locations
    /// @param isReference Set if an argument is label-only, as in the
    ///     compound name foo(_:in:)
    /// @return Labels of the arguments ("_" if none) and of the
    ///     trailing closures, or nil for a subscript
    private func suffixLabels(_ suffix: any SyntaxNode, text: NSString, shape: inout CallShape, isReference: inout Bool) -> [String]? {
        var labels: [String] = []
        for i in 0..<suffix.childCount {
            guard let child = suffix.child(at: i) else { continue }
            switch child.nodeType {
            case "value_arguments":
                if child.child(at: 0)?.nodeType == "[" {
                    return nil
                }
                for j in 0..<child.childCount {
                    guard let arg = child.child(at: j), arg.nodeType == "value_argument" else { continue }
                    if arg.lastChild?.nodeType == ":" {
                        isReference = true
                    }
                    labels.append(argumentLabel(of: arg, text: text, shape: &shape))
                }
            case "lambda_literal":
                // A labeled trailing closure follows "label :"
                let label = i >= 2 && suffix.fieldName(forChildAt: i - 2) == "name" ? suffix.child(at: i - 2).flatMap { Self.identifierText($0, text: text) } : nil
                labels.append((label ?? "") + "{}")
            default:
                if suffix.fieldName(forChildAt: i) == "name" {
                    shape.labelLocations.append(child.range.location)
                }
            }
        }
        return labels
    }

    /// @brief Gets one argument's label, keeping the label out of the
    /// usage counts.
    /// @param arg A value_argument node
    /// @param text The file's text
    /// @param shape Collects the label's location
    /// @return The label, or "_" if the argument has none
    private func argumentLabel(of arg: any SyntaxNode, text: NSString, shape: inout CallShape) -> String {
        var label: String?
        for k in 0..<arg.childCount {
            let field = arg.fieldName(forChildAt: k)
            guard field == "name" || field == "reference_specifier", let labelNode = arg.child(at: k) else { continue }
            shape.labelLocations.append(labelNode.range.location)
            if label == nil {
                label = Self.identifierText(labelNode, text: text)
            }
        }
        return label ?? "_"
    }

    /// @brief Finds the identifier a call calls.
    /// @details
    /// foo(...) calls foo; a.b.foo(...) and .foo(...) call the last
    /// navigation suffix.
    /// @param callee The call_expression's first child
    /// @return The name node, or nil if the callee isn't a name
    private func calleeName(_ callee: any SyntaxNode) -> (any SyntaxNode)? {
        switch callee.nodeType {
        case "simple_identifier":
            return callee
        case "navigation_expression", "prefix_expression":
            guard let last = callee.lastChild else { return nil }
            if last.nodeType == "simple_identifier" {
                return last
            }
            guard last.nodeType == "navigation_suffix", let name = last.lastChild, name.nodeType == "simple_identifier" else { return nil }
            return name
        default:
            return nil
        }
    }

    /// @brief An identifier's text, without Swift's escaping backticks.
    /// @param node The identifier
    /// @param text The file's text
    /// @return Its name, or nil when its range is outside the text
    private static func identifierText(_ node: any SyntaxNode, text: NSString) -> String? {
        let range = node.range
        guard range.location >= 0, NSMaxRange(range) <= text.length else {
            return nil
        }
        return text.substring(with: range).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    }
}
