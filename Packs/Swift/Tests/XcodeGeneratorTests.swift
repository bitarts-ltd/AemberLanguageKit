/**
    @file XcodeGeneratorTests.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Tests for XcodeGenerator.
    @details
    Parses canned xcodebuild build logs (clang invocations and swiftc
    driver lines that reference SwiftFileLists), and runs the generator
    against a fake xcodebuild shell script to cover project and scheme
    detection, the clean and build invocations, and failures.
*/

import Foundation
import Testing
import AemberLanguageKit
import PackTestSupport
@testable import SwiftPack

@Suite("XcodeGenerator")
struct XcodeGeneratorTests {

    /// Toolchain prefix used in canned compiler lines
    private static let toolchain = "/Applications/Xcode.app/Contents/"
        + "Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"

    /// @brief A canned clang invocation for one source file.
    /// @param source The source file path
    /// @return An indented xcodebuild log line
    private static func clangLine(_ source: String) -> String {
        return "    \(toolchain)/clang -x objective-c -fobjc-arc "
            + "-I/proj/include -c \(source) -o /dd/main.o"
    }

    /// @brief A canned swiftc driver line using a SwiftFileList.
    /// @param fileList Path of the SwiftFileList
    /// @param workingDirectory Value of -working-directory
    /// @return An indented xcodebuild log line
    private static func swiftLine(
        fileList: String,
        workingDirectory: String
    ) -> String {
        return "    builtin-SwiftDriver -- \(toolchain)/swiftc "
            + "-module-name App -Onone @\(fileList) -c -j10 "
            + "-working-directory \(workingDirectory)"
    }

    // MARK: - Log parsing

    /// @brief clang lines yield one command each, in the project root
    /// until a -working-directory is seen.
    @Test func parsesClangInvocations() {
        let log = [
            "CompileC /dd/main.o /proj/src/main.m normal arm64 objective-c",
            "    cd /proj",
            Self.clangLine("/proj/src/main.m"),
            "",
            "    \(Self.toolchain)/clang++ -std=c++20 -c /proj/x.cpp -o x.o",
            "    \(Self.toolchain)/clang -c /proj/plain.c",
            "    \(Self.toolchain)/clang++ -c /proj/obj.mm -o obj.o",
            "    \(Self.toolchain)/clang -c /proj/header.h",
            "    \(Self.toolchain)/clang -o app main.o",
            "Ld /dd/App normal",
        ].joined(separator: "\n")
        let commands = XcodeGenerator().parseCompilationCommands(
            from: log,
            projectURL: URL(fileURLWithPath: "/proj")
        )
        #expect(commands.map(\.file)
            == ["/proj/src/main.m", "/proj/x.cpp", "/proj/plain.c",
                "/proj/obj.mm"])
        #expect(commands.allSatisfy { $0.directory == "/proj" })
        #expect(commands.first?.command
            == Self.clangLine("/proj/src/main.m")
                .trimmingCharacters(in: .whitespaces))
        #expect(commands.allSatisfy { $0.output == nil })
    }

    /// @brief swiftc lines expand to one command per SwiftFileList entry
    /// and set the working directory for later lines.
    @Test func parsesSwiftFileLists() throws {
        let fixture = try BuildSystemFixture()
        let fileList = try fixture.write(
            "App.SwiftFileList",
            "/proj/A.swift\n  /proj/B.swift  \n\n"
        )
        let swift = Self.swiftLine(
            fileList: fileList.path,
            workingDirectory: "/work"
        )
        let log = [
            swift,
            Self.clangLine("/proj/after.m"),
        ].joined(separator: "\n")
        let commands = XcodeGenerator().parseCompilationCommands(
            from: log,
            projectURL: URL(fileURLWithPath: "/proj")
        )
        #expect(commands.map(\.file)
            == ["/proj/A.swift", "/proj/B.swift", "/proj/after.m"])
        #expect(commands.map(\.directory) == ["/work", "/work", "/work"])

        // The builtin-SwiftDriver prefix is stripped from the command
        let command = try #require(commands.first?.command)
        #expect(command.hasPrefix("\(Self.toolchain)/swiftc "))
        #expect(command.hasSuffix("-working-directory /work"))
    }

    /// @brief swiftc lines without a readable file list yield nothing.
    @Test(arguments: [
        "    swiftc -module-name App -c a.swift b.swift",
        "    swiftc -module-name App @/no/such/App.SwiftFileList -c",
    ])
    func skipsSwiftWithoutFileList(line: String) {
        let commands = XcodeGenerator().parseCompilationCommands(
            from: line,
            projectURL: URL(fileURLWithPath: "/proj")
        )
        #expect(commands.isEmpty)
    }

    /// @brief Logs without compiler invocations yield nothing.
    @Test(arguments: ["", "** BUILD SUCCEEDED **\n", "Ld /dd/App normal\n"])
    func emptyLogs(log: String) {
        #expect(
            XcodeGenerator().parseCompilationCommands(
                from: log,
                projectURL: URL(fileURLWithPath: "/proj")
            ).isEmpty
        )
    }

    // MARK: - Generation with a fake xcodebuild

    /// @brief Create a fixture with a fake xcodebuild.
    /// @detail
    /// The fake logs each invocation's arguments to calls.txt, prints
    /// `schemes` for -list, and prints `buildLog` for build.
    /// @param bundles Project or workspace bundles to create
    /// @param schemes Scheme names printed by -list -json
    /// @param buildLog Output printed by build
    /// @param buildStatus Exit status of build
    /// @return The fixture and a generator that runs the fake
    private func makeProject(
        bundles: [String] = ["App.xcodeproj"],
        schemes: [String] = ["App", "AppTests"],
        buildLog: String? = nil,
        buildStatus: Int = 0
    ) throws -> (BuildSystemFixture, XcodeGenerator) {
        let fixture = try BuildSystemFixture()
        for bundle in bundles {
            try fixture.makeDirectory(bundle)
        }
        let listing = try JSONSerialization.data(withJSONObject: [
            "project": ["name": "App", "schemes": schemes]
        ])
        try listing.write(to: fixture.url("list.txt"))
        try fixture.write(
            "build.txt",
            buildLog ?? Self.clangLine(fixture.url("main.m").path) + "\n"
        )
        let calls = fixture.url("calls.txt").path
        let xcodebuild = try fixture.writeScript("tools/xcodebuild", """
            echo "$*" >> "\(calls)"
            case " $* " in
            *" -list "*)
                cat "\(fixture.url("list.txt").path)" ;;
            *" build "*)
                cat "\(fixture.url("build.txt").path)"
                echo "build stderr" >&2
                exit \(buildStatus) ;;
            esac
            """)
        return (fixture, XcodeGenerator(executablePath: xcodebuild.path))
    }

    /// @brief Read the logged xcodebuild invocations.
    /// @param fixture The project fixture
    /// @return One line of arguments per invocation
    private func calls(_ fixture: BuildSystemFixture) throws -> [String] {
        return try fixture.read("calls.txt")
            .split(separator: "\n").map(String.init)
    }

    /// @brief The scheme named like the project is used to build it in
    /// the generator's own folder, without a clean, and the parsed
    /// commands are written to .aember.
    @Test func generatesDatabase() async throws {
        let (fixture, generator) = try makeProject(
            schemes: ["AppTests", "App"]
        )
        let output = OutputLines()
        let result = try await generator.generate(
            projectURL: fixture.root,
            onOutput: output.append
        )
        #expect(result == fixture.url(".aember/compile_commands.json"))
        let derivedData = generator.derivedDataURL(for: fixture.root).path
        #expect(try calls(fixture) == [
            "-list -json -project App.xcodeproj",
            "-project App.xcodeproj -scheme App -configuration Debug "
                + "-derivedDataPath \(derivedData) build",
        ])
        let commands = try JSONDecoder().decode(
            [CompileCommand].self,
            from: Data(contentsOf: result)
        )
        #expect(commands.map(\.file) == [fixture.url("main.m").path])
        #expect(output.lines.contains("Using scheme: App"))
        #expect(output.lines.last == "Generated compilation database")
    }

    /// @brief A workspace is preferred over a project.
    @Test func prefersWorkspace() async throws {
        let (fixture, generator) = try makeProject(
            bundles: ["App.xcodeproj", "App.xcworkspace"]
        )
        _ = try await generator.generate(projectURL: fixture.root)
        #expect(try calls(fixture).first
            == "-list -json -workspace App.xcworkspace")
    }

    /// @brief An explicit project and scheme skip detection.
    @Test func usesExplicitProjectAndScheme() async throws {
        let (fixture, generator) = try makeProject(bundles: [])
        _ = try await generator.generate(
            projectURL: fixture.root,
            project: "Other.xcodeproj",
            scheme: "Custom"
        )
        let derivedData = generator.derivedDataURL(for: fixture.root).path
        #expect(try calls(fixture) == [
            "-project Other.xcodeproj -scheme Custom -configuration Debug "
                + "-derivedDataPath \(derivedData) build",
        ])
    }

    /// @brief Each generation starts from an empty build folder, so a
    /// second one still compiles, and logs, every file.
    @Test func emptiesItsBuildFolderFirst() async throws {
        let (fixture, generator) = try makeProject()
        let derivedData = generator.derivedDataURL(for: fixture.root)
        let leftover = derivedData.appendingPathComponent("leftover")
        try FileManager.default.createDirectory(
            at: derivedData,
            withIntermediateDirectories: true
        )
        try Data().write(to: leftover)
        defer { try? FileManager.default.removeItem(at: derivedData) }

        _ = try await generator.generate(projectURL: fixture.root)

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    /// @brief Projects at different paths get different build folders.
    @Test func buildFolderIsPerProject() {
        let generator = XcodeGenerator()
        let one = generator.derivedDataURL(for: URL(fileURLWithPath: "/a/App"))
        let two = generator.derivedDataURL(for: URL(fileURLWithPath: "/b/App"))
        #expect(one != two)
        #expect(one.lastPathComponent.hasPrefix("App-"))
    }

    /// @brief A folder without a project or workspace is an error.
    @Test func noProjectOrWorkspace() async throws {
        let (fixture, generator) = try makeProject(bundles: [])
        let error = await #expect(throws: XcodeGeneratorError.self) {
            _ = try await generator.generate(projectURL: fixture.root)
        }
        guard case .noProjectOrWorkspace? = error else {
            Issue.record("Unexpected error: \(String(describing: error))")
            return
        }
    }

    /// @brief A project without schemes is an error.
    @Test func noSchemes() async throws {
        let (fixture, generator) = try makeProject(schemes: [])
        let error = await #expect(throws: XcodeGeneratorError.self) {
            _ = try await generator.generate(projectURL: fixture.root)
        }
        guard case .noSchemeAvailable? = error else {
            Issue.record("Unexpected error: \(String(describing: error))")
            return
        }
    }

    /// @brief A failing build reports its stderr.
    @Test func buildFailureReportsStderr() async throws {
        let (fixture, generator) = try makeProject(buildStatus: 65)
        let error = await #expect(throws: XcodeGeneratorError.self) {
            _ = try await generator.generate(projectURL: fixture.root)
        }
        guard case .buildFailed(let message)? = error else {
            Issue.record("Unexpected error: \(String(describing: error))")
            return
        }
        #expect(message.contains("build stderr"))
    }

    /// @brief A build log without compiler invocations is an error.
    @Test func noCompilationCommands() async throws {
        let (fixture, generator) = try makeProject(
            buildLog: "** BUILD SUCCEEDED **\n"
        )
        let error = await #expect(throws: CompilationDatabaseError.self) {
            _ = try await generator.generate(projectURL: fixture.root)
        }
        guard case .noCompilationCommands? = error else {
            Issue.record("Unexpected error: \(String(describing: error))")
            return
        }
        #expect(!fixture.exists(".aember/compile_commands.json"))
    }

    /// @brief Every error has a non-empty description.
    @Test(arguments: [
        XcodeGeneratorError.noProjectOrWorkspace,
        .noSchemeAvailable,
        .buildFailed("details"),
    ])
    func errorDescriptions(error: XcodeGeneratorError) {
        #expect(error.errorDescription?.isEmpty == false)
    }
}
