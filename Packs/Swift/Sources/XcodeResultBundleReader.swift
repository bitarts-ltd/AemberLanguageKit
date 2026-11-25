/**
    @file XcodeResultBundleReader.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Reads the Xcode result bundles xcodebuild writes.
    @details
    Reads an .xcresult bundle through `xcrun xcresulttool`: `get
    build-results` gives the errors and warnings, each place a file URL
    whose fragment holds 0-based StartingLineNumber and
    StartingColumnNumber; `get test-results tests` gives the tree of
    test plans, bundles, suites and test cases, each case with its
    result, duration and failure messages with their (1-based) places.
    Tests are named Target/identifier, as `-only-testing:` takes them.
    The Xcode build system's commands name their bundle as a report
    of the `xcresult` format, which this reads.
*/

import Foundation
import AemberLanguageKit

// l10n-exempt-file: reads xcresulttool's English node types

/// @brief Reads Xcode result bundles.
enum XcodeResultBundleReader {

    /// @brief Runs xcresulttool with arguments and returns its stdout,
    /// or nil when it fails; replaceable in tests
    typealias Tool = @Sendable ([String]) -> Data?

    /// The format Xcode's commands name their bundles with
    static let format = "xcresult"

    /// The pack's reader for it
    static let reader = BuildReportReader(identifier: format) { read(bundle: $0) }

    /// @brief Reads a bundle's diagnostics and tests.
    /// @param bundle The .xcresult bundle
    /// @param tool Runs xcresulttool
    /// @return The diagnostics and tests, each nil when unreadable
    static func read(bundle: URL, tool: Tool = runXCResultTool) -> BuildReport {
        let build = tool(["get", "build-results", "--path", bundle.path, "--compact"])
        let tests = tool(["get", "test-results", "tests", "--path", bundle.path, "--compact"])
        return BuildReport(diagnostics: build.flatMap(diagnostics(fromBuildResults:)), tests: tests.flatMap(tests(fromTestResults:)))
    }

    /// @brief The diagnostics in `get build-results` JSON.
    /// @param data The JSON
    /// @return Errors, then warnings; nil when it isn't build results
    static func diagnostics(fromBuildResults data: Data) -> [BuildDiagnostic]? {
        guard let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
            object["errors"] != nil || object["warnings"] != nil
        else {
            return nil
        }
        func issues(_ key: String, _ severity: BuildSeverity) -> [BuildDiagnostic] {
            (object[key] as? [[String: Any]] ?? []).compactMap { issue in
                guard let message = issue["message"] as? String else {
                    return nil
                }
                let place = (issue["sourceURL"] as? String).flatMap(place(of:))
                return BuildDiagnostic(
                    path: place?.path,
                    line: place?.line,
                    column: place?.column,
                    severity: severity,
                    message: message
                )
            }
        }
        return issues("errors", .error) + issues("warnings", .warning)
    }

    /// @brief A file and 1-based line and column from an issue's
    /// source URL.
    /// @param sourceURL file:///path#...StartingLineNumber=N... (0-based)
    /// @return The place, or nil for a URL without a file
    static func place(of sourceURL: String) -> (path: String, line: Int?, column: Int?)? {
        guard let url = URL(string: sourceURL), url.isFileURL else {
            return nil
        }
        var values: [String: Int] = [:]
        for pair in (url.fragment ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let value = Int(parts[1]) {
                values[String(parts[0])] = value
            }
        }
        return (
            url.path,
            values["StartingLineNumber"].map { $0 + 1 },
            values["StartingColumnNumber"].map { $0 + 1 }
        )
    }

    /// @brief The test cases in `get test-results tests` JSON.
    /// @param data The JSON
    /// @return Every test case; nil when it isn't test results
    static func tests(fromTestResults data: Data) -> [BuildTestResult]? {
        guard let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
            let nodes = object["testNodes"] as? [[String: Any]]
        else {
            return nil
        }
        var results: [BuildTestResult] = []
        for node in nodes {
            collect(node, target: nil, into: &results)
        }
        return results
    }

    /// @brief Adds a node's test cases, depth first.
    private static func collect(
        _ node: [String: Any],
        target: String?,
        into results: inout [BuildTestResult]
    ) {
        let type = node["nodeType"] as? String ?? ""
        let name = node["name"] as? String ?? ""
        var target = target
        if type.hasSuffix("test bundle") {
            target = name
        }
        let children = node["children"] as? [[String: Any]] ?? []
        guard type == "Test Case" else {
            for child in children {
                collect(child, target: target, into: &results)
            }
            return
        }

        let identifier = node["nodeIdentifier"] as? String ?? name
        let outcome: BuildTestOutcome
        switch node["result"] as? String ?? "" {
        case "Failed": outcome = .failed
        case "Skipped": outcome = .skipped
        default: outcome = .passed
        }
        var result = BuildTestResult(
            name: target.map { $0 + "/" + identifier } ?? identifier,
            displayName: identifier.hasPrefix(name)
                || identifier.hasSuffix("/" + name) ? nil : name,
            outcome: outcome,
            duration: node["durationInSeconds"] as? Double
        )
        var messages: [String] = []
        failures(in: children) { message, location in
            messages.append(message)
            if result.path == nil, let location {
                result.path = location["filePath"] as? String
                result.line = location["lineNumber"] as? Int
            }
        }
        if !messages.isEmpty {
            result.message = messages.joined(separator: "\n")
        }
        results.append(result)
    }

    /// @brief Calls found for each failure message under nodes, with
    /// its source location if it has one.
    private static func failures(
        in nodes: [[String: Any]],
        found: (String, [String: Any]?) -> Void
    ) {
        for node in nodes {
            let type = node["nodeType"] as? String ?? ""
            if type == "Failure Message" || type == "Skip Message",
               let message = node["name"] as? String {
                found(message, node["sourceLocation"] as? [String: Any])
            }
            failures(
                in: node["children"] as? [[String: Any]] ?? [],
                found: found
            )
        }
    }

    /// @brief Runs `xcrun xcresulttool` and returns its stdout.
    /// @param arguments The tool's arguments
    /// @return stdout, or nil when it exits with an error
    static func runXCResultTool(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcresulttool"] + arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = process.readToEndAndWait(output: output, error: error)
        return process.terminationStatus == 0 ? data.output : nil
    }
}
