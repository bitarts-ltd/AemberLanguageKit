/**
    @file PackageCheck.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Newer versions and known vulnerabilities of a project's packages
    @details
    Check for Updates asks each package manager which of its packages
    have newer versions (PackageUpdate: the newest the dependency's rule
    allows, and the newest there is) and which have known
    vulnerabilities (PackageAdvisory), giving a PackageCheckResult per
    backend. Results name the version they were found for, so a package
    updated since shows no stale badge. The backends' checks are in
    PackageBackendChecks.swift; this file holds the model, which
    versions a rule allows (Swift's rules and npm's ranges,
    NPMVersionRange), and the summary the status bar and the Packages
    folder show. Checking needs the network, so it only runs when the
    user asks or the daily check is on. Aember words the badges and
    the summary itself.
*/

import Foundation

// MARK: - Results

/// @brief Newer versions of one package
public struct PackageUpdate: Equatable, Sendable {

    /// The package's id in its graph
    public var packageID: String

    /// The version checked, the resolved one then
    public var current: String

    /// The newest version the dependency's rule allows, when newer than
    /// current; nil when none is or the rule isn't known
    public var compatible: String?

    /// The newest version there is, when newer than current
    public var latest: String?

    /// @brief An update.
    /// @param packageID The package's id
    /// @param current The version checked
    /// @param compatible The newest the rule allows
    /// @param latest The newest there is
    /// @return The update
    public init(packageID: String, current: String, compatible: String? = nil, latest: String? = nil) {
        self.packageID = packageID
        self.current = current
        self.compatible = compatible
        self.latest = latest
    }

    /// @brief The newest version found.
    public var newest: String {
        latest ?? compatible ?? current
    }

    /// @brief Whether the newest version is outside the rule, so taking
    /// it changes the rule.
    public var isOutsideRule: Bool {
        guard let latest else { return false }
        return latest != compatible
    }

    /// @brief An update from a package's versions.
    /// @detail
    /// Pre-releases count only when the current version is one.
    /// @param packageID The package's id
    /// @param current Its resolved version
    /// @param versions Its versions, in any order
    /// @param latest The newest release as the registry tags it (npm's
    /// latest dist-tag), else the newest of versions
    /// @param allows Whether the dependency's rule allows a version;
    /// nil when the rule isn't known
    /// @return The update, or nil when nothing is newer
    public static func from(
        packageID: String,
        current: String,
        versions: [String],
        latest: String? = nil,
        allows: ((String) -> Bool)?
    ) -> PackageUpdate? {
        let takesPrereleases = !PackageVersion.isRelease(current) && PackageVersion.parts(current) != nil
        let newer = PackageVersion.newestFirst(versions.filter {
            (takesPrereleases || PackageVersion.isRelease($0)) && PackageVersion.isOlder(current, than: $0)
        })
        let newest = latest.flatMap { PackageVersion.isOlder(current, than: $0) ? $0 : nil }
            ?? (latest == nil ? newer.first : nil)
        let compatible = allows.flatMap { allows in newer.first(where: allows) }
        guard newest != nil || compatible != nil else { return nil }
        return PackageUpdate(packageID: packageID, current: current, compatible: compatible, latest: newest)
    }
}

/// @brief A known vulnerability in a package
public struct PackageAdvisory: Equatable, Sendable {

    /// The package's id in its graph
    public var packageID: String

    /// The version it was found in, the resolved one then
    public var version: String?

    /// The advisory's id (GHSA-…, RUSTSEC-…)
    public var identifier: String

    /// What it is
    public var title: String

    /// low, moderate, high or critical, as the tool says; nil if it
    /// doesn't
    public var severity: String?

    /// Its page
    public var url: URL?

    /// @brief An advisory.
    /// @param packageID The package's id
    /// @param version The version it was found in
    /// @param identifier The advisory's id
    /// @param title What it is
    /// @param severity How serious, as the tool says
    /// @param url Its page
    /// @return The advisory
    public init(packageID: String, version: String? = nil, identifier: String, title: String, severity: String? = nil, url: URL? = nil) {
        self.packageID = packageID
        self.version = version
        self.identifier = identifier
        self.title = title
        self.severity = severity
        self.url = url
    }

    /// @brief The advisory in one line, for tooltips and menus.
    public var description: String {
        guard let severity, !severity.isEmpty else {
            return "\(identifier): \(title)"
        }
        // l10n-exempt: severities are the tools' own words
        return "\(identifier) (\(severity)): \(title)"
    }
}

/// @brief What one package manager's check found
public struct PackageCheckResult: Equatable, Sendable {

    /// When it was checked
    public var date: Date

    /// Packages with newer versions
    public var updates: [PackageUpdate] = []

    /// Known vulnerabilities
    public var advisories: [PackageAdvisory] = []

    /// What couldn't be checked, and why (localized lines)
    public var problems: [String] = []

    /// @brief A check's result.
    /// @param date When it was checked
    /// @param updates Packages with newer versions
    /// @param advisories Known vulnerabilities
    /// @param problems What couldn't be checked
    /// @return The result
    public init(date: Date, updates: [PackageUpdate] = [], advisories: [PackageAdvisory] = [], problems: [String] = []) {
        self.date = date
        self.updates = updates
        self.advisories = advisories
        self.problems = problems
    }

    /// @brief A package's update, if it is still at the version checked.
    /// @param package The package
    /// @return The update, or nil
    public func update(for package: ResolvedPackage) -> PackageUpdate? {
        updates.first { $0.packageID == package.id && $0.current == package.version }
    }

    /// @brief A package's advisories, if it is still at the version
    /// checked.
    /// @param package The package
    /// @return The advisories
    public func advisories(for package: ResolvedPackage) -> [PackageAdvisory] {
        advisories.filter { $0.packageID == package.id && ($0.version == nil || $0.version == package.version) }
    }

    /// @brief How many packages of a graph have updates and advisories
    /// still.
    /// @param graph The graph read now
    /// @return The packages with updates, and the advisories
    public func counts(in graph: PackageGraph) -> (updates: Int, advisories: Int) {
        var updates = 0
        var advisories = 0
        for package in graph.packages {
            if update(for: package) != nil {
                updates += 1
            }
            advisories += self.advisories(for: package).count
        }
        return (updates, advisories)
    }


}

// MARK: - Rules

extension VersionRule {

    /// @brief Whether the rule allows a version.
    /// @detail
    /// SwiftPM's rules by their bounds; a requirement as an npm range
    /// (NPMVersionRange). Branches, revisions, paths and ranges that
    /// don't read give nil.
    /// @param version The version
    /// @return Whether it's allowed, or nil if the rule can't say
    public func allows(_ version: String) -> Bool? {
        switch self {
        case .upToNextMajor(let lower):
            guard let parts = PackageVersion.parts(lower) else { return nil }
            return PackageVersion.isWithin(version, lower: lower, upper: "\((parts.numbers.first ?? 0) + 1).0.0")
        case .upToNextMinor(let lower):
            guard let parts = PackageVersion.parts(lower) else { return nil }
            let major = parts.numbers.first ?? 0
            let minor = parts.numbers.count > 1 ? parts.numbers[1] : 0
            return PackageVersion.isWithin(version, lower: lower, upper: "\(major).\(minor + 1).0")
        case .exact(let exact):
            return !PackageVersion.isOlder(version, than: exact) && !PackageVersion.isOlder(exact, than: version)
        case .range(let lower, let upper):
            return PackageVersion.isWithin(version, lower: lower, upper: upper)
        case .requirement(let requirement):
            return NPMVersionRange(requirement)?.allows(version)
        case .branch, .revision, .path:
            return nil
        }
    }

    /// @brief The rule that allows a newer version, of the same kind:
    /// exact stays exact, a range or requirement becomes "from" it (^),
    /// up to next minor stays so.
    /// @param version The version
    /// @param bareIsExact Whether a requirement written as a bare
    /// version (1.2.3) means exactly it, as npm's does, rather than ^,
    /// as Cargo's does
    /// @return The rule, or nil for branches, revisions and paths
    public func allowing(_ version: String, bareIsExact: Bool) -> VersionRule? {
        switch self {
        case .upToNextMajor, .range:
            return .upToNextMajor(version)
        case .upToNextMinor:
            return .upToNextMinor(version)
        case .exact:
            return .exact(version)
        case .requirement(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("~") {
                return .upToNextMinor(version)
            }
            let isBare = PackageVersion.isRelease(trimmed) && PackageVersion.parts(trimmed)?.numbers.count == 3 && trimmed.first?.isNumber == true
            if trimmed.hasPrefix("=") || bareIsExact && isBare {
                return .exact(version)
            }
            return .upToNextMajor(version)
        case .branch, .revision, .path:
            return nil
        }
    }
}

extension PackageVersion {

    /// @brief Whether a version is at or above a lower bound and below
    /// an upper one.
    /// @param version The version
    /// @param lower The lowest allowed
    /// @param upper The first not allowed
    /// @return true if within
    public static func isWithin(_ version: String, lower: String, upper: String) -> Bool {
        !isOlder(version, than: lower) && isOlder(version, than: upper)
    }
}

// MARK: - npm Ranges

/// @brief An npm version range (^1.2.0, ~1.2, >=1 <2, 1.x || 2, 1 - 2)
public struct NPMVersionRange: Sendable {

    /// @brief One bound of a comparator set
    private struct Bound {
        var version: String
        var inclusive: Bool
    }

    /// @brief Versions in a set are within both bounds
    private struct ComparatorSet {
        var lower: Bound?
        var upper: Bound?
        var exact: String?
    }

    /// The sets, any of which allows a version
    private let sets: [ComparatorSet]

    /// Whether the range names a pre-release, so pre-releases can match
    private let mentionsPrerelease: Bool

    /// @brief Reads a range.
    /// @param text The range, as package.json writes it
    /// @return nil for what isn't a version range (a tag, a URL, a
    /// file: or git: dependency)
    public init?(_ text: String) {
        var sets: [ComparatorSet] = []
        for part in text.components(separatedBy: "||") {
            guard let set = Self.parseSet(part.trimmingCharacters(in: .whitespaces)) else { return nil }
            sets.append(set)
        }
        guard !sets.isEmpty else { return nil }
        self.sets = sets
        mentionsPrerelease = text.contains("-") && !text.contains(" - ")
    }

    /// @brief Whether the range allows a version.
    /// @param version The version
    /// @return true if a set allows it
    public func allows(_ version: String) -> Bool {
        guard PackageVersion.parts(version) != nil else { return false }
        if !PackageVersion.isRelease(version) && !mentionsPrerelease {
            return false
        }
        return sets.contains { set in
            if let exact = set.exact {
                return !PackageVersion.isOlder(version, than: exact) && !PackageVersion.isOlder(exact, than: version)
            }
            if let lower = set.lower {
                if PackageVersion.isOlder(version, than: lower.version) {
                    return false
                }
                if !lower.inclusive && !PackageVersion.isOlder(lower.version, than: version) {
                    return false
                }
            }
            if let upper = set.upper {
                if PackageVersion.isOlder(upper.version, than: version) {
                    return false
                }
                if !upper.inclusive && !PackageVersion.isOlder(version, than: upper.version) {
                    return false
                }
            }
            return true
        }
    }

    /// @brief A version with x, X or * parts, or parts left out.
    private struct Partial {
        var numbers: [Int]
        var prerelease: String?

        /// The version with missing parts as 0
        var floor: String {
            var parts = numbers
            while parts.count < 3 {
                parts.append(0)
            }
            return parts.map(String.init).joined(separator: ".") + (prerelease.map { "-" + $0 } ?? "")
        }

        /// The first version past what the partial covers (1.2 → 1.3.0)
        var ceiling: String? {
            guard !numbers.isEmpty else { return nil }
            var parts = numbers
            parts[parts.count - 1] += 1
            while parts.count < 3 {
                parts.append(0)
            }
            return parts.map(String.init).joined(separator: ".")
        }

        /// Whether all three numbers were given
        var isFull: Bool {
            numbers.count >= 3
        }
    }

    /// @brief Reads a partial version (1, 1.2, 1.x, 1.2.3-beta, *).
    private static func parsePartial(_ text: String) -> Partial? {
        var value = Substring(text)
        if value.first == "v" || value.first == "=" {
            value = value.dropFirst()
        }
        if value.isEmpty || value == "*" || value == "x" || value == "X" {
            return Partial(numbers: [])
        }
        value = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? value
        let pieces = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for piece in pieces[0].split(separator: ".", omittingEmptySubsequences: false) {
            if piece == "x" || piece == "X" || piece == "*" {
                break
            }
            guard let number = Int(piece), numbers.count < 3 else { return nil }
            numbers.append(number)
        }
        return Partial(numbers: numbers, prerelease: pieces.count > 1 ? String(pieces[1]) : nil)
    }

    /// @brief Reads one comparator set: comparators separated by
    /// spaces, or a hyphen range.
    private static func parseSet(_ text: String) -> ComparatorSet? {
        if text.isEmpty || text == "*" || text == "latest" || text == "x" {
            return ComparatorSet()
        }
        let hyphen = text.components(separatedBy: " - ")
        if hyphen.count == 2 {
            guard let low = parsePartial(hyphen[0].trimmingCharacters(in: .whitespaces)),
                  let high = parsePartial(hyphen[1].trimmingCharacters(in: .whitespaces))
            else {
                return nil
            }
            var set = ComparatorSet(lower: Bound(version: low.floor, inclusive: true))
            if high.isFull {
                set.upper = Bound(version: high.floor, inclusive: true)
            } else if let ceiling = high.ceiling {
                set.upper = Bound(version: ceiling, inclusive: false)
            }
            return set
        }
        // Join an operator to the version after it ("> = 1" isn't npm's)
        let joined = text.replacingOccurrences(of: #"(>=|<=|>|<|=|\^|~)\s+"#, with: "$1", options: .regularExpression)
        var set = ComparatorSet()
        for comparator in joined.split(separator: " ").map(String.init) {
            guard apply(comparator, to: &set) else { return nil }
        }
        return set
    }

    /// @brief Narrows a set by one comparator.
    /// @return false if the comparator doesn't read
    private static func apply(_ comparator: String, to set: inout ComparatorSet) -> Bool {
        let operators = [">=", "<=", ">", "<", "^", "~=", "~>", "~", "="]
        let op = operators.first { comparator.hasPrefix($0) } ?? ""
        guard let partial = parsePartial(String(comparator.dropFirst(op.count))) else { return false }
        func raise(_ version: String, inclusive: Bool) {
            if let lower = set.lower, PackageVersion.isOlder(version, than: lower.version) {
                return
            }
            set.lower = Bound(version: version, inclusive: inclusive)
        }
        func lower(_ version: String, inclusive: Bool) {
            if let upper = set.upper, PackageVersion.isOlder(upper.version, than: version) {
                return
            }
            set.upper = Bound(version: version, inclusive: inclusive)
        }
        let numbers = partial.numbers
        switch op {
        case "^":
            raise(partial.floor, inclusive: true)
            guard !numbers.isEmpty else { return true }
            // The first non-zero part given is the one that can't change
            let index = numbers.firstIndex { $0 != 0 } ?? (numbers.count - 1)
            var parts = Array(numbers.prefix(index + 1))
            parts[index] += 1
            while parts.count < 3 {
                parts.append(0)
            }
            lower(parts.map(String.init).joined(separator: "."), inclusive: false)
        case "~", "~>", "~=":
            raise(partial.floor, inclusive: true)
            guard !numbers.isEmpty else { return true }
            let kept = Array(numbers.prefix(numbers.count == 1 ? 1 : 2))
            if let ceiling = Partial(numbers: kept).ceiling {
                lower(ceiling, inclusive: false)
            }
        case ">=":
            raise(partial.floor, inclusive: true)
        case ">":
            if partial.isFull {
                raise(partial.floor, inclusive: false)
            } else if let ceiling = partial.ceiling {
                raise(ceiling, inclusive: true)
            } else {
                // >* allows nothing
                lower("0.0.0", inclusive: false)
            }
        case "<":
            lower(partial.floor, inclusive: false)
        case "<=":
            if partial.isFull {
                lower(partial.floor, inclusive: true)
            } else if let ceiling = partial.ceiling {
                lower(ceiling, inclusive: false)
            }
        default:
            if partial.isFull {
                set.exact = partial.floor
            } else {
                raise(partial.floor, inclusive: true)
                if let ceiling = partial.ceiling {
                    lower(ceiling, inclusive: false)
                }
            }
        }
        return true
    }
}

// MARK: - Running Checks

public enum PackageCheckRunner: Sendable {

    /// The most network requests or tool runs a check makes at once
    public static let concurrency = 6

    /// @brief Runs work on items, a few at a time, keeping their order.
    /// @param items The items
    /// @param work The work on one
    /// @return The results, in the items' order
    public static func map<Item, Result>(_ items: [Item], _ work: @escaping (Item) async -> Result) async -> [Result] {
        var results = [Result?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, Result).self) { group in
            var next = 0
            func start() {
                guard next < items.count else { return }
                let index = next
                let item = items[index]
                next += 1
                group.addTask { (index, await work(item)) }
            }
            for _ in 0..<min(concurrency, items.count) {
                start()
            }
            while let (index, result) = await group.next() {
                results[index] = result
                start()
            }
        }
        return results.compactMap { $0 }
    }
}

// MARK: - Shared Check Helpers

extension PackageCheckRunner {

    /// @brief Updates of packages from their versions.
    /// @param packages The packages to check, each with a version
    /// @param graph The graph, for direct dependencies' rules
    /// @param versions A package's versions and newest tagged release;
    /// nil to skip it; throws when it couldn't be listed
    /// @return The updates, and the names of packages that failed
    public static func updates(
        of packages: [ResolvedPackage],
        in graph: PackageGraph,
        versions: @escaping (ResolvedPackage) async throws -> (versions: [String], latest: String?)?
    ) async -> (updates: [PackageUpdate], failed: [String]) {
        let results = await map(packages) { package -> (PackageUpdate?, String?) in
            guard let current = package.version else { return (nil, nil) }
            do {
                guard let found = try await versions(package) else { return (nil, nil) }
                let rule = graph.dependencies.first { $0.resolvedID == package.id }?.rule
                let allows: ((String) -> Bool)? = rule.flatMap { rule in
                    rule.allows(current) == nil ? nil : { rule.allows($0) == true }
                }
                return (PackageUpdate.from(packageID: package.id, current: current, versions: found.versions, latest: found.latest, allows: allows), nil)
            } catch {
                return (nil, package.name)
            }
        }
        return (results.compactMap(\.0), results.compactMap(\.1))
    }

    /// @brief The problem line for packages whose versions couldn't be
    /// listed.
    /// @param names Their names
    /// @param format The line, localized, with %@ for the names
    /// ("Couldn’t list the versions of %@.")
    /// @return The line, or nil for none
    public static func failedProblem(_ names: [String], format: String) -> String? {
        guard !names.isEmpty else { return nil }
        return String(format: format, ListFormatter.localizedString(byJoining: names.sorted()))
    }

    /// @brief The problem line for a tool that failed: the first line it
    /// printed, in its own words, else its error's description, as
    /// Aember words it.
    /// @param command The command line
    /// @param message What it printed
    /// @return The line
    public static func toolProblem(_ command: String, _ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line.map(String.init) ?? PackageError.toolFailed(command: command, message: message).localizedDescription
    }
}
