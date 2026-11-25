/**
    @file PackageWorkspaces.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief Finding a JavaScript workspace's members
    @details
    npm and Yarn list a workspace's members in package.json's
    "workspaces" (an array of patterns, or Yarn's {"packages": [...]}),
    pnpm in pnpm-workspace.yaml's "packages". The patterns are folder
    globs (packages then a star, apps then two stars, "tools/cli"),
    with "!" excluding;
    a member is a folder matching one that holds a package.json. Folders
    are matched by path component: "*" and other wildcards within one
    name (fnmatch), "**" any number of folders. node_modules, hidden
    folders and the root itself are never members.
*/

import Foundation
import AemberLanguageKit

/// @brief A JavaScript workspace's members
enum PackageWorkspaces {

    /// @brief The member patterns package.json lists.
    /// @param manifest package.json's object
    /// @return Its "workspaces" patterns, or none
    static func patterns(in manifest: [String: Any]) -> [String] {
        if let list = manifest["workspaces"] as? [String] {
            return list
        }
        return (manifest["workspaces"] as? [String: Any])?["packages"] as? [String] ?? []
    }

    /// @brief The member patterns pnpm-workspace.yaml lists.
    /// @param text The file's text
    /// @return Its "packages" patterns, or none
    static func pnpmPatterns(_ text: String) -> [String] {
        (LockfileText.parse(text)["packages"] as? [Any] ?? []).compactMap { $0 as? String }
    }

    /// @brief The member folders patterns match.
    /// @param patterns The patterns; "!" ones exclude
    /// @param root The workspace root
    /// @param manifest The file a member must hold ("package.json")
    /// @return The members' paths relative to root, sorted
    static func folders(matching patterns: [String], in root: URL, manifest: String = "package.json") -> [String] {
        var included = Set<String>()
        var excluded = Set<String>()
        for raw in patterns {
            let isNegated = raw.hasPrefix("!")
            var pattern = isNegated ? String(raw.dropFirst()) : raw
            while pattern.hasPrefix("./") {
                pattern.removeFirst(2)
            }
            while pattern.hasSuffix("/") {
                pattern.removeLast()
            }
            let components = pattern.split(separator: "/").map(String.init)
            guard !components.isEmpty, !components.contains("..") else { continue }
            let matches = expand(components, under: root, path: "")
            if isNegated {
                excluded.formUnion(matches)
            } else {
                included.formUnion(matches)
            }
        }
        let fileManager = FileManager.default
        return included.subtracting(excluded)
            .filter { !$0.isEmpty && fileManager.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent(manifest).path) }
            .sorted()
    }

    /// @brief The folders matching a pattern's remaining components.
    /// @param components The components left
    /// @param root The workspace root
    /// @param path The folder matched so far, relative to root
    /// @return The matching folders' paths
    private static func expand(_ components: [String], under root: URL, path: String) -> Set<String> {
        guard let first = components.first else { return [path] }
        let rest = Array(components.dropFirst())
        func join(_ name: String) -> String {
            path.isEmpty ? name : path + "/" + name
        }
        if first == "**" {
            var result = expand(rest, under: root, path: path)
            for name in subfolders(of: root.appendingPathComponent(path)) {
                result.formUnion(expand(components, under: root, path: join(name)))
            }
            return result
        }
        guard first.contains(where: { "*?[".contains($0) }) else {
            var isFolder: ObjCBool = false
            let url = root.appendingPathComponent(join(first))
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else { return [] }
            return expand(rest, under: root, path: join(first))
        }
        var result = Set<String>()
        for name in subfolders(of: root.appendingPathComponent(path)) where fnmatch(first, name, 0) == 0 {
            result.formUnion(expand(rest, under: root, path: join(name)))
        }
        return result
    }

    /// @brief A folder's subfolders that can hold members.
    /// @param folder The folder
    /// @return Their names, without node_modules and hidden folders
    private static func subfolders(of folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { name in
            guard !name.hasPrefix("."), name != "node_modules" else { return false }
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isFolder) && isFolder.boolValue
        }.sorted()
    }

    /// @brief A member's name and its package.json, read.
    /// @param path The member's folder, relative to root
    /// @param root The workspace root
    /// @return Its name (the folder's when package.json names none),
    /// whether package.json names it, and the object; nil if unreadable
    static func readMember(_ path: String, in root: URL) -> (name: String, hasName: Bool, manifest: [String: Any], url: URL)? {
        let url = root.appendingPathComponent(path).appendingPathComponent("package.json")
        guard let object = try? PackageJSON.object(at: url) else { return nil }
        let name = object["name"] as? String
        return (name ?? URL(fileURLWithPath: path).lastPathComponent, name != nil, object, url)
    }
}
