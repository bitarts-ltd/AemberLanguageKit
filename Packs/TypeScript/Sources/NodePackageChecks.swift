/**
    @file NodePackageChecks.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Check for Updates for npm, pnpm and Yarn
    @details
    - npm asks the registry (the project's or user's .npmrc, else
      registry.npmjs.org) for each direct dependency's versions,
      compares them with package-lock.json, and matches its range
      (NPMVersionRange); `npm outdated` would need node_modules
      installed. `npm audit --json` gives the advisories.
    - pnpm and Yarn ask the registries as npm does, with their own
      lockfile's versions. `pnpm audit --json` and Yarn 1's `yarn audit
      --json` (a line of JSON per advisory) report in npm's older
      format (advisories with findings by version); Yarn 2+'s `yarn npm
      audit --all --recursive --json` gives a line per advisory with
      the versions in the tree.

    The parsers are static, for tests with saved output.
*/

import Foundation
import AemberLanguageKit

// MARK: - npm

/// @brief The npm registries a project uses, from .npmrc
struct NPMRegistryConfiguration: Equatable {

    /// The default registry
    var registry = URL(string: "https://registry.npmjs.org")!

    /// Registries by scope (@scope), lower cased
    var scoped: [String: URL] = [:]

    /// @brief The configuration for a project: its .npmrc's entries
    /// over the user's.
    /// @param folder The project's folder
    /// @param home The user's home folder
    /// @return The configuration
    static func load(
        for folder: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> NPMRegistryConfiguration {
        var configuration = NPMRegistryConfiguration()
        for file in [home.appendingPathComponent(".npmrc"), folder.appendingPathComponent(".npmrc")] {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                configuration.read(text)
            }
        }
        return configuration
    }

    /// @brief Takes an .npmrc's registry lines over what is set.
    /// @detail
    /// "registry=URL" sets the default, "@scope:registry=URL" a
    /// scope's; other lines and comments are ignored.
    /// @param text The file
    /// @return Nothing
    mutating func read(_ text: String) {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix(";"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            guard let url = URL(string: value.hasSuffix("/") ? String(value.dropLast()) : value), url.scheme?.hasPrefix("http") == true else { continue }
            if key == "registry" {
                registry = url
            } else if key.hasPrefix("@"), key.hasSuffix(":registry") {
                scoped[String(key.dropLast(":registry".count)).lowercased()] = url
            }
        }
    }

    /// @brief The registry serving a package.
    /// @param name The package's name (@scope/name or name)
    /// @return Its scope's registry, else the default
    func registry(for name: String) -> URL {
        guard name.hasPrefix("@"), let slash = name.firstIndex(of: "/") else { return registry }
        return scoped[name[..<slash].lowercased()] ?? registry
    }
}

extension NPMBackend {

    func check(graph: PackageGraph, http: PackageHTTP) async -> PackageCheckResult {
        await Self.check(
            graph: graph,
            registries: NPMRegistryConfiguration.load(for: folder),
            http: http,
            runner: runner,
            folder: folder
        )
    }

    /// @brief Asks the registries for the direct dependencies'
    /// versions, then runs npm audit.
    /// @param graph The graph
    /// @param registries The registries to ask
    /// @param http The client
    /// @param runner Runs npm
    /// @param folder The manifest's folder
    /// @return What was found
    static func check(
        graph: PackageGraph,
        registries: NPMRegistryConfiguration,
        http: PackageHTTP,
        runner: PackageToolRunner,
        folder: URL
    ) async -> PackageCheckResult {
        await NodePackageChecks.check(graph: graph, registries: registries, http: http) {
            audit(graph: graph, runner: runner, folder: folder)
        }
    }

    /// @brief The packages whose versions are asked for: the direct
    /// dependencies from the registry, with a version range.
    /// @param graph The graph
    /// @return The resolved packages
    static func checkedPackages(in graph: PackageGraph) -> [ResolvedPackage] {
        NodePackageChecks.checkedPackages(in: graph)
    }

    /// @brief Runs `npm audit --json`.
    /// @param graph The graph
    /// @param runner Runs npm
    /// @param folder The manifest's folder
    /// @return The advisories, and why there are none when it failed
    static func audit(graph: PackageGraph, runner: PackageToolRunner, folder: URL) -> (advisories: [PackageAdvisory], problem: String?) {
        NodePackageChecks.audit(tool: toolName, arguments: ["audit", "--json"], runner: runner, folder: folder) { output in
            // l10n-exempt: a command's name
            guard let object = try? PackageJSON.object(output.output, name: "npm audit") else { return nil }
            if let error = object["error"] as? [String: Any] {
                return .failure(error["summary"] as? String ?? error["code"] as? String ?? "")
            }
            return .success(parseAudit(object, graph: graph))
        }
    }
}

// MARK: - npm-like

/// @brief The check npm, pnpm and Yarn share, and the audit reports
/// they print
enum NodePackageChecks {

    /// What an audit's output said: advisories, or the tool's error
    enum AuditOutcome {
        case success([PackageAdvisory])
        case failure(String)
    }

    /// @brief Asks the registries for the direct dependencies'
    /// versions, then runs an audit.
    /// @param graph The graph
    /// @param registries The registries to ask
    /// @param http The client
    /// @param audit Runs the tool's audit (blocking; run detached)
    /// @return What was found
    static func check(
        graph: PackageGraph,
        registries: NPMRegistryConfiguration,
        http: PackageHTTP,
        audit: @escaping @Sendable () -> (advisories: [PackageAdvisory], problem: String?)
    ) async -> PackageCheckResult {
        let found = await PackageCheckRunner.updates(of: checkedPackages(in: graph), in: graph) { package in
            let name = graph.dependencies.first { $0.resolvedID == package.id }?.name ?? package.name
            let source = NPMRegistrySearch(baseURL: registries.registry(for: name), http: http)
            let versions = try await source.details(of: PackageSearchResult(name: name, location: name)).versions
            // The latest dist-tag comes first
            return (versions, versions.first)
        }
        var result = PackageCheckResult(date: Date(), updates: found.updates)
        if let problem = PackageCheckRunner.failedProblem(found.failed, format: PackStrings.text("Couldn’t list the versions of %@.").localized) {
            result.problems.append(problem)
        }
        let audited = await Task.detached { () -> (advisories: [PackageAdvisory], problem: String?) in
            audit()
        }.value
        result.advisories = audited.advisories
        if let problem = audited.problem {
            result.problems.append(problem)
        }
        return result
    }

    /// @brief Runs an audit and reads its output.
    /// @detail
    /// Audits exit with an error when they find something, so the
    /// output is read whatever the status; output that doesn't read is
    /// the problem, with what the tool printed.
    /// @param tool The tool ("npm", "pnpm", "yarn")
    /// @param arguments Its arguments
    /// @param runner Runs it
    /// @param folder The manifest's folder
    /// @param parse Reads the output; nil when it isn't the report
    /// @return The advisories, and why there are none when it failed
    static func audit(
        tool: String,
        arguments: [String],
        runner: PackageToolRunner,
        folder: URL,
        parse: (PackageToolResult) -> AuditOutcome?
    ) -> (advisories: [PackageAdvisory], problem: String?) {
        let command = ([tool] + arguments).joined(separator: " ")
        do {
            let output = try runner.run(tool, arguments: arguments, in: folder)
            switch parse(output) {
            case .success(let advisories)?:
                return (advisories, nil)
            case .failure(let message)?:
                return ([], PackageCheckRunner.toolProblem(command, message))
            case nil:
                return ([], PackageCheckRunner.toolProblem(command, output.errorText))
            }
        } catch {
            return ([], error.localizedDescription)
        }
    }

    /// @brief The JSON objects on an output's lines (Yarn's --json).
    /// @param data The output
    /// @return The lines that are objects
    static func jsonLines(_ data: Data) -> [[String: Any]] {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
    }

    /// @brief Reads advisories in npm's older audit format, which pnpm
    /// audit and Yarn 1's yarn audit print.
    /// @detail
    /// Each advisory names its module and, in its findings, the
    /// versions it was found at; every package with that name and one
    /// of those versions gets it. The id is the GitHub advisory's when
    /// given, else the end of its URL, else its number.
    /// @param advisories The advisory objects
    /// @param graph The graph
    /// @return The advisories of packages in the graph
    static func parseLegacyAdvisories(_ advisories: [[String: Any]], graph: PackageGraph) -> [PackageAdvisory] {
        var result: [PackageAdvisory] = []
        for advisory in advisories {
            guard let module = advisory["module_name"] as? String else { continue }
            let versions = Set((advisory["findings"] as? [[String: Any]] ?? []).compactMap { $0["version"] as? String })
            let url = (advisory["url"] as? String).flatMap(URL.init(string:))
            let identifier = advisory["github_advisory_id"] as? String ?? url?.lastPathComponent ?? (advisory["id"].map { "\($0)" } ?? module)
            for package in graph.packages where package.name == module && (versions.isEmpty || package.version.map(versions.contains) == true) {
                result.append(PackageAdvisory(
                    packageID: package.id,
                    version: package.version,
                    identifier: identifier,
                    title: advisory["title"] as? String ?? identifier,
                    severity: advisory["severity"] as? String,
                    url: url
                ))
            }
        }
        return result
    }

    /// @brief Reads Yarn 2+'s `yarn npm audit --json` lines.
    /// @detail
    /// Each line names a package (value) and one advisory (children:
    /// ID, Issue, URL, Severity, and the versions in the tree).
    /// @param lines The output's JSON lines
    /// @param graph The graph
    /// @return The advisories of packages in the graph
    static func parseModernYarnAudit(_ lines: [[String: Any]], graph: PackageGraph) -> [PackageAdvisory] {
        var result: [PackageAdvisory] = []
        for line in lines {
            guard let name = line["value"] as? String, let details = line["children"] as? [String: Any] else { continue }
            let versions = Set(details["Tree Versions"] as? [String] ?? [])
            let url = (details["URL"] as? String).flatMap(URL.init(string:))
            let identifier = url?.lastPathComponent ?? (details["ID"].map { "\($0)" } ?? name)
            for package in graph.packages where package.name == name && (versions.isEmpty || package.version.map(versions.contains) == true) {
                result.append(PackageAdvisory(
                    packageID: package.id,
                    version: package.version,
                    identifier: identifier,
                    title: details["Issue"] as? String ?? identifier,
                    severity: details["Severity"] as? String,
                    url: url
                ))
            }
        }
        return result
    }

    /// @brief The packages whose versions are asked for: the direct
    /// dependencies from the registry, with a version range.
    /// @param graph The graph
    /// @return The resolved packages
    static func checkedPackages(in graph: PackageGraph) -> [ResolvedPackage] {
        graph.dependencies.compactMap { dependency in
            guard case .requirement(let text)? = dependency.rule, NPMVersionRange(text) != nil,
                  let package = dependency.resolvedID.flatMap(graph.package),
                  case .registry = package.source
            else {
                return nil
            }
            return package
        }
    }
}

extension NPMBackend {

    /// @brief Reads `npm audit --json`'s report (version 2).
    /// @detail
    /// Each vulnerable package's "via" lists its own advisories as
    /// objects, and the packages it is vulnerable through as names;
    /// only the advisories are kept. "nodes" are its lockfile paths,
    /// the graph's ids.
    /// @param object The report
    /// @param graph The graph
    /// @return The advisories of packages in the graph
    static func parseAudit(_ object: [String: Any], graph: PackageGraph) -> [PackageAdvisory] {
        guard let vulnerabilities = object["vulnerabilities"] as? [String: Any] else { return [] }
        var advisories: [PackageAdvisory] = []
        for name in vulnerabilities.keys.sorted() {
            guard let entry = vulnerabilities[name] as? [String: Any] else { continue }
            let nodes = entry["nodes"] as? [String] ?? graph.packages.filter { $0.name == name }.map(\.id)
            let via = (entry["via"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            for node in nodes {
                guard let package = graph.package(node) else { continue }
                for advisory in via {
                    let url = (advisory["url"] as? String).flatMap(URL.init(string:))
                    let identifier = url?.lastPathComponent ?? (advisory["source"].map { "\($0)" } ?? name)
                    advisories.append(PackageAdvisory(
                        packageID: package.id,
                        version: package.version,
                        identifier: identifier,
                        title: advisory["title"] as? String ?? identifier,
                        severity: advisory["severity"] as? String,
                        url: url
                    ))
                }
            }
        }
        return advisories
    }
}

// MARK: - pnpm

extension PNPMBackend {

    func check(graph: PackageGraph, http: PackageHTTP) async -> PackageCheckResult {
        let runner = runner
        let folder = folder
        return await NodePackageChecks.check(graph: graph, registries: NPMRegistryConfiguration.load(for: folder), http: http) {
            Self.audit(graph: graph, runner: runner, folder: folder)
        }
    }

    /// @brief Runs `pnpm audit --json`.
    /// @param graph The graph
    /// @param runner Runs pnpm
    /// @param folder The manifest's folder
    /// @return The advisories, and why there are none when it failed
    static func audit(graph: PackageGraph, runner: PackageToolRunner, folder: URL) -> (advisories: [PackageAdvisory], problem: String?) {
        NodePackageChecks.audit(tool: toolName, arguments: ["audit", "--json"], runner: runner, folder: folder) { output in
            // l10n-exempt: a command's name
            guard let object = try? PackageJSON.object(output.output, name: "pnpm audit") else { return nil }
            if let error = object["error"] as? [String: Any] {
                return .failure(error["message"] as? String ?? error["code"] as? String ?? "")
            }
            return parseAudit(object, graph: graph).map { .success($0) }
        }
    }

    /// @brief Reads `pnpm audit --json`'s report.
    /// @param object The report
    /// @param graph The graph
    /// @return The advisories, or nil when it isn't a report
    static func parseAudit(_ object: [String: Any], graph: PackageGraph) -> [PackageAdvisory]? {
        guard let advisories = object["advisories"] as? [String: Any] else { return nil }
        let sorted = advisories.keys.sorted().compactMap { advisories[$0] as? [String: Any] }
        return NodePackageChecks.parseLegacyAdvisories(sorted, graph: graph)
    }
}

// MARK: - Yarn

extension YarnBackend {

    func check(graph: PackageGraph, http: PackageHTTP) async -> PackageCheckResult {
        let runner = runner
        let folder = folder
        let modern = Self.isModern(folder: folder)
        return await NodePackageChecks.check(graph: graph, registries: NPMRegistryConfiguration.load(for: folder), http: http) {
            Self.audit(graph: graph, modern: modern, runner: runner, folder: folder)
        }
    }

    /// @brief The audit command's arguments.
    /// @param modern Whether the project uses Yarn 2+
    /// @return `audit --json`, or Yarn 2+'s `npm audit` over every
    /// workspace and the packages under the direct ones
    static func auditArguments(modern: Bool) -> [String] {
        modern ? ["npm", "audit", "--all", "--recursive", "--json"] : ["audit", "--json"]
    }

    /// @brief Runs Yarn's audit.
    /// @param graph The graph
    /// @param modern Whether the project uses Yarn 2+
    /// @param runner Runs yarn
    /// @param folder The manifest's folder
    /// @return The advisories, and why there are none when it failed
    static func audit(graph: PackageGraph, modern: Bool, runner: PackageToolRunner, folder: URL) -> (advisories: [PackageAdvisory], problem: String?) {
        NodePackageChecks.audit(tool: toolName, arguments: auditArguments(modern: modern), runner: runner, folder: folder) { output in
            parseAudit(output, modern: modern, graph: graph).map { .success($0) }
        }
    }

    /// @brief Reads Yarn's audit output.
    /// @detail
    /// Both print a JSON object a line. Yarn 1's auditAdvisory lines
    /// hold advisories in npm's older format; Yarn 2+'s lines are one
    /// advisory each. A clean audit may print no JSON at all, which is
    /// no advisories when Yarn exited without an error.
    /// @param output What the audit printed and how it exited
    /// @param modern Whether it was Yarn 2+'s
    /// @param graph The graph
    /// @return The advisories, or nil when the output isn't a report
    static func parseAudit(_ output: PackageToolResult, modern: Bool, graph: PackageGraph) -> [PackageAdvisory]? {
        let lines = NodePackageChecks.jsonLines(output.output)
        guard !lines.isEmpty else { return output.status == 0 ? [] : nil }
        if modern {
            return NodePackageChecks.parseModernYarnAudit(lines, graph: graph)
        }
        let advisories = lines.compactMap { line -> [String: Any]? in
            guard line["type"] as? String == "auditAdvisory" else { return nil }
            return (line["data"] as? [String: Any])?["advisory"] as? [String: Any]
        }
        // Yarn 1 always ends with its summary; an error line alone isn't
        // a report
        guard !advisories.isEmpty || lines.contains(where: { $0["type"] as? String == "auditSummary" }) else { return nil }
        return NodePackageChecks.parseLegacyAdvisories(advisories, graph: graph)
    }
}
