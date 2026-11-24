/**
    @file CargoChecks.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Check for Updates for Cargo
    @details
    Cargo runs `cargo update --dry-run --verbose`, whose "Updating a
    v1 -> v2" and "Unchanged a v1 (available: v3)" lines give both the
    newest the rule allows and the newest there is, and `cargo audit
    --json` when cargo-audit is installed. The parsers are static, for
    tests with saved output.
*/

import Foundation
import AemberLanguageKit

extension CargoBackend {

    func check(graph: PackageGraph, http: PackageHTTP) async -> PackageCheckResult {
        let runner = runner
        let folder = folder
        return await Task.detached {
            Self.check(graph: graph, runner: runner, folder: folder)
        }.value
    }

    /// @brief Runs the dry run and, when installed, cargo audit.
    /// @param graph The graph
    /// @param runner Runs cargo
    /// @param folder The manifest's folder
    /// @return What was found
    static func check(graph: PackageGraph, runner: PackageToolRunner, folder: URL) -> PackageCheckResult {
        var result = PackageCheckResult(date: Date())
        let dryRun = ["update", "--dry-run", "--verbose"]
        do {
            let output = try runner.run(toolName, arguments: dryRun, in: folder)
            if output.status == 0 {
                result.updates = parseDryRun(output.errorText, graph: graph)
            } else {
                result.problems.append(PackageCheckRunner.toolProblem((["cargo"] + dryRun).joined(separator: " "), output.errorText))
            }
        } catch {
            result.problems.append(error.localizedDescription)
        }
        guard runner.find("cargo-audit") != nil else {
            result.problems.append(PackStrings.text("Advisories weren’t checked: cargo-audit isn’t installed. Install it with “cargo install cargo-audit”.").localized)
            return result
        }
        let audit = ["audit", "--json"]
        do {
            let output = try runner.run(toolName, arguments: audit, in: folder)
            // l10n-exempt: a command's name
            if let object = try? PackageJSON.object(output.output, name: "cargo audit") {
                result.advisories = parseAudit(object, graph: graph)
            } else {
                result.problems.append(PackageCheckRunner.toolProblem((["cargo"] + audit).joined(separator: " "), output.errorText))
            }
        } catch {
            result.problems.append(error.localizedDescription)
        }
        return result
    }

    /// @brief Reads `cargo update --dry-run --verbose`'s report.
    /// @detail
    /// "Updating name v1 -> v2" gives v2 as the newest the requirements
    /// allow; "(available: v3)" (or "(latest: v3)") after a line, the
    /// newest there is. "Unchanged name v1 (available: v3)" has only
    /// the latter. Packages match the graph by name and version.
    /// @param text What the dry run printed (its standard error)
    /// @param graph The graph
    /// @return The updates
    static func parseDryRun(_ text: String, graph: PackageGraph) -> [PackageUpdate] {
        let pattern = #"^\s*(Updating|Unchanged)\s+(\S+)\s+v(\S+)(?:\s+->\s+v(\S+))?(?:\s+\((?:available|latest):\s+v([^)\s]+)\))?\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        var updates: [PackageUpdate] = []
        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = expression.firstMatch(in: line, range: range) else { continue }
            func group(_ index: Int) -> String? {
                guard let bounds = Swift.Range<String.Index>(match.range(at: index), in: line) else { return nil }
                return String(line[bounds])
            }
            guard let name = group(2), let current = group(3),
                  let package = graph.packages.first(where: { $0.name == name && $0.version == current })
            else {
                continue
            }
            let compatible = group(4)
            let latest = group(5) ?? compatible
            guard compatible != nil || latest != nil else { continue }
            updates.append(PackageUpdate(packageID: package.id, current: current, compatible: compatible, latest: latest))
        }
        return updates
    }

    /// @brief Reads `cargo audit --json`'s report.
    /// @param object The report
    /// @param graph The graph, for the packages' ids
    /// @return The advisories of packages in the graph
    static func parseAudit(_ object: [String: Any], graph: PackageGraph) -> [PackageAdvisory] {
        let list = (object["vulnerabilities"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let advisory = entry["advisory"] as? [String: Any],
                  let identifier = advisory["id"] as? String,
                  let package = entry["package"] as? [String: Any],
                  let name = package["name"] as? String
            else {
                return nil
            }
            let version = package["version"] as? String
            guard let resolved = graph.packages.first(where: { $0.name == name && (version == nil || $0.version == version) }) else {
                return nil
            }
            let url = (advisory["url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://rustsec.org/advisories/\(identifier)")
            return PackageAdvisory(
                packageID: resolved.id,
                version: resolved.version,
                identifier: identifier,
                title: advisory["title"] as? String ?? identifier,
                severity: nil,
                url: url
            )
        }
    }
}
