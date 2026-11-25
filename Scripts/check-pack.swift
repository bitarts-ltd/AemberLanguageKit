/**
    @file check-pack.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief
    Checks a language pack as Aember loads it, and lists what it gives.
    @details
    Built and run by Scripts/check-pack.sh, linked with
    AemberLanguageKit.xcframework, so the pack uses the checker's copy
    of the SDK as it uses Aember's. Reads the pack's embedded
    Info.plist without running it, checks its keys and API version,
    loads it (dlopen, then aember_language_pack), checks the manifest
    against the plist, activates it, and lists its languages, servers,
    build systems and package managers. Exits 1 on the first problem.
*/

import AemberLanguageKit
import Foundation
import MachO

/// @brief Prints a problem and exits.
/// @param message The problem
/// @return Never
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// @brief The __TEXT,__info_plist section of a thin or universal
/// Mach-O file, from this machine's slice.
/// @param data The file
/// @return The section's bytes, or nil
func infoPlistSection(in data: Data) -> Data? {
    func read<T: FixedWidthInteger>(_ type: T.Type, at offset: Int, bigEndian: Bool = false) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= data.count else {
            return nil
        }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        return bigEndian ? T(bigEndian: value) : T(littleEndian: value)
    }
    var base = 0
    if read(UInt32.self, at: 0, bigEndian: true) == FAT_MAGIC {
        #if arch(arm64)
        let wanted = CPU_TYPE_ARM64
        #else
        let wanted = CPU_TYPE_X86_64
        #endif
        let count = Int(read(UInt32.self, at: 4, bigEndian: true) ?? 0)
        guard let slice = (0..<count).first(where: { read(Int32.self, at: 8 + $0 * 20, bigEndian: true) == wanted }) else {
            return nil
        }
        base = Int(read(UInt32.self, at: 8 + slice * 20 + 8, bigEndian: true) ?? 0)
    }
    guard read(UInt32.self, at: base) == MH_MAGIC_64, let commands = read(UInt32.self, at: base + 16) else {
        return nil
    }
    var offset = base + 32
    for _ in 0..<commands {
        guard let command = read(UInt32.self, at: offset), let size = read(UInt32.self, at: offset + 4) else {
            return nil
        }
        if command == LC_SEGMENT_64, let sections = read(UInt32.self, at: offset + 64) {
            for index in 0..<Int(sections) {
                let section = offset + 72 + index * 80
                let name = String(decoding: data[section..<section + 16].prefix { $0 != 0 }, as: UTF8.self)
                let segment = String(decoding: data[section + 16..<section + 32].prefix { $0 != 0 }, as: UTF8.self)
                if segment == "__TEXT", name == "__info_plist", let length = read(UInt64.self, at: section + 40), let start = read(UInt32.self, at: section + 48) {
                    let from = base + Int(start)
                    return data[from..<from + Int(length)]
                }
            }
        }
        offset += Int(size)
    }
    return nil
}

/// @brief Settings kept in memory
final class CheckSettings: LanguagePackSettings, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func value(forKey key: String) -> Any? { values[key] }
    func setValue(_ value: Any?, forKey key: String) { values[key] = value }
}

/// @brief What the checker gives the pack in place of Aember
final class CheckContext: LanguagePackContext, @unchecked Sendable {
    let appVersion = "check-pack"
    let apiVersion = LanguagePackAPI.version
    private let settings = CheckSettings()
    func log(_ message: String) { print("  log: \(message)") }
    func settings(for scope: LanguagePackScope) -> any LanguagePackSettings { settings }
    func findExecutable(named name: String, also directories: [String]) -> URL? {
        let paths = directories + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: check-pack <pack.aemberpack>")
}
let path = CommandLine.arguments[1]
guard let data = FileManager.default.contents(atPath: path) else {
    fail("can't read \(path)")
}
guard let section = infoPlistSection(in: data) else {
    fail("no __TEXT,__info_plist section for this Mac's architecture; link with -sectcreate __TEXT __info_plist Info.plist")
}
guard let plist = try? PropertyListSerialization.propertyList(from: section, format: nil) as? [String: Any] else {
    fail("the embedded Info.plist isn't a property list")
}
func string(_ key: String) -> String {
    guard let value = plist[key] as? String, !value.isEmpty else {
        fail("Info.plist has no \(key)")
    }
    return value
}
let id = string(LanguagePackInfoKey.identifier)
let name = string(LanguagePackInfoKey.name)
let versionString = string(LanguagePackInfoKey.version)
let apiString = string(LanguagePackInfoKey.apiVersion)
let bundleIdentifier = string(LanguagePackInfoKey.bundleIdentifier)
guard id == id.lowercased(), !id.contains(where: \.isWhitespace) else {
    fail("AemberPackID \"\(id)\" must be lowercase, without spaces")
}
guard URL(fileURLWithPath: path).lastPathComponent == "\(id).\(LanguagePackAPI.fileExtension)" else {
    fail("the file must be named \(id).\(LanguagePackAPI.fileExtension)")
}
guard let version = LanguagePackVersion(versionString) else {
    fail("CFBundleShortVersionString \"\(versionString)\" isn't a version")
}
guard let api = LanguagePackVersion(apiString) else {
    fail("AemberPackAPIVersion \"\(apiString)\" isn't a version")
}
guard LanguagePackAPI.isCompatible(api, with: LanguagePackAPI.version) else {
    fail("built for API \(apiString); this SDK is \(LanguagePackAPI.version), and a 0.x API needs the same minor version")
}
print("\(name) (\(id)) \(version), API \(apiString), \(bundleIdentifier)")

guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
    fail("can't load it: \(String(cString: dlerror()))")
}
guard let symbol = dlsym(handle, LanguagePackAPI.entrySymbol) else {
    fail("no \(LanguagePackAPI.entrySymbol) function; export one with @_cdecl(\"\(LanguagePackAPI.entrySymbol)\")")
}
typealias Entry = @convention(c) () -> UnsafeMutableRawPointer
let entry = unsafeBitCast(symbol, to: Entry.self)
guard let pack = LanguagePackAPI.take(entry()) else {
    fail("\(LanguagePackAPI.entrySymbol) returned something that isn't a LanguagePack; was the pack linked with another copy of AemberLanguageKit?")
}
guard pack.manifest.id == id else {
    fail("the manifest's id \"\(pack.manifest.id)\" isn't the Info.plist's AemberPackID \"\(id)\"")
}
guard pack.manifest.version == version else {
    fail("the manifest's version \(pack.manifest.version) isn't the Info.plist's \(version)")
}

pack.activate(context: CheckContext())
print("Languages:")
for language in pack.languages {
    let files = language.extensions.map { ".\($0)" } + language.fileNames + language.fileNamePrefixes.map { "\($0)*" } + language.shebangInterpreters.map { "#!…\($0)" }
    var parts = [files.joined(separator: " ")]
    if let grammar = language.grammar {
        guard grammar.language() != nil else {
            fail("\(language.id)'s grammar function returned nil")
        }
        parts.append("grammar")
    }
    if language.queries.highlights != nil || language.inheritsQueriesFrom != nil {
        parts.append("highlights")
    }
    if let lsp = language.lspLanguageID {
        parts.append("LSP \(lsp)")
    }
    print("  \(language.id) (\(language.displayName.english)): \(parts.joined(separator: ", "))")
}
print("Language servers:")
for server in pack.languageServers {
    print("  \(server.name): \(server.executable) for \(server.languages.joined(separator: ", "))")
}
print("Build systems:")
for provider in pack.buildSystems {
    print("  \(provider.identifier), priority \(provider.priority)")
}
print("Package managers:")
for backend in pack.packageBackends {
    print("  \(backend.identifier) (\(backend.displayName))")
}
pack.deactivate()
print("OK")
