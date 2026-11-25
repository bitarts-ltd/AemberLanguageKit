/**
    @file SwiftCallShapeTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Unit tests for SwiftCallShape.
    @details
    Covers shape keys, reading parameters from signatures (labels,
    defaults, variadics, closures, nested brackets and strings), and
    whether call shapes bind to parameters: exact labels, skipped
    defaults, variadics, and unlabeled and labeled trailing closures.
*/

import Foundation
import Testing
@testable import SwiftPack

@Suite("SwiftCallShape")
struct SwiftCallShapeTests {

    /// @brief Shorthand for a parameter.
    private func param(
        _ label: String,
        default hasDefault: Bool = false,
        variadic: Bool = false,
        closure: Bool = false
    ) -> SwiftCallShape.Parameter {
        return SwiftCallShape.Parameter(
            label: label, hasDefault: hasDefault,
            isVariadic: variadic, isClosure: closure
        )
    }

    /// @brief Whether a call shape binds to a signature.
    private func accepts(_ key: String, _ signature: String) throws -> Bool {
        let params = try #require(
            SwiftCallShape.parameters(of: signature), "\(signature)"
        )
        return SwiftCallShape.accepts(key, parameters: params)
    }

    // MARK: - Keys

    /// @brief Keys join labels with commas; no arguments is "".
    @Test func keys() {
        #expect(SwiftCallShape.key([]) == "")
        #expect(SwiftCallShape.key(["_", "at", "{}"]) == "_,at,{}")
    }

    // MARK: - Parameters

    /// @brief Labels, defaults, variadics, and closures.
    @Test func readsParameters() {
        #expect(SwiftCallShape.parameters(of: "()") == [])
        #expect(SwiftCallShape.parameters(of: "() -> Int") == [])
        #expect(SwiftCallShape.parameters(
            of: "(_ a: Int, with b: String = \"x, y\", c: Int...) -> Bool"
        ) == [
            param("_"),
            param("with", default: true),
            param("c", variadic: true),
        ])
        #expect(SwiftCallShape.parameters(
            of: "(completion: @escaping (Result<Int, Error>) -> Void)"
        ) == [param("completion", closure: true)])
        #expect(SwiftCallShape.parameters(
            of: "(map: [String: (Int, Int)] = [:], `in` x: Int)"
        ) == [param("map", default: true), param("in")])
    }

    /// @brief Signatures without a readable list are nil.
    @Test func unreadableSignatures() {
        #expect(SwiftCallShape.parameters(of: "") == nil)
        #expect(SwiftCallShape.parameters(of: ": Int") == nil)
        #expect(SwiftCallShape.parameters(of: "(a: Int") == nil)
        #expect(SwiftCallShape.parameters(of: "(Int, String)") == nil)
    }

    // MARK: - Matching

    /// @brief Labels must match in order.
    @Test func exactLabels() throws {
        #expect(try accepts("at,in", "(at a: Int, in b: Int)"))
        #expect(try !accepts("at", "(named n: String)"))
        #expect(try !accepts("in,at", "(at a: Int, in b: Int)"))
        #expect(try accepts("", "()"))
        #expect(try !accepts("_", "()"))
        #expect(try !accepts("", "(_ x: Int)"))
        #expect(try !accepts("_,_", "(_ x: Int)"))
    }

    /// @brief Defaulted parameters may be left out anywhere.
    @Test func defaultsMayBeSkipped() throws {
        let sig = "(_ a: Int, b: Int = 0, c: Int = 1)"
        #expect(try accepts("_", sig))
        #expect(try accepts("_,c", sig))
        #expect(try accepts("_,b,c", sig))
        #expect(try !accepts("_,c,b", sig))
        #expect(try !accepts("b", sig))
    }

    /// @brief Variadics take any number of arguments.
    @Test func variadics() throws {
        let sig = "(_ items: Int..., separator: String = \" \")"
        #expect(try accepts("", sig))
        #expect(try accepts("_", sig))
        #expect(try accepts("_,_,_,separator", sig))
        #expect(try !accepts("separator,_", sig))
    }

    /// @brief A trailing closure binds to the next closure
    /// parameter it can reach, or else the next parameter.
    @Test func trailingClosures() throws {
        let sig = "(_ x: Int, animated: Bool = true, "
            + "completion: @escaping () -> Void)"
        #expect(try accepts("_,{}", sig))
        #expect(try accepts("_,animated,{}", sig))
        #expect(try accepts("_,completion", sig))
        #expect(try !accepts("{}", sig))

        // No closure parameter: bind to the next one
        #expect(try accepts("_,{}", "(_ x: Int, body: Any)"))
        #expect(try !accepts("_,{}", "(_ x: Int)"))
    }

    /// @brief Labeled trailing closures bind by label.
    @Test func labeledTrailingClosures() throws {
        let sig = "(content: () -> Void, other: () -> Void, "
            + "footer: (() -> Void)? = nil)"
        #expect(try accepts("{},other{}", sig))
        #expect(try accepts("{},other{},footer{}", sig))
        #expect(try !accepts("{},footer{}", sig))
    }
}
