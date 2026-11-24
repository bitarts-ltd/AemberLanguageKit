/**
    @file PackTestSupport.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief What the included packs' tests share: saved tool output, a fake
    tool runner, temporary folders and a stub HTTP service.
    @details
    PackageFixtures reads saved tool output from a folder, by default the
    Fixtures folder beside the test file that makes it.
    FakePackageToolRunner answers each command with saved output and
    records what was run, so backends are tested without the tools.
    StubHTTPService answers a URLSession's requests with the test's
    handlers, so searches and checks are tested without the network.
    These came from Aember's tests, which use the same ones.
*/

import Foundation
import AemberLanguageKit

// MARK: - Fixtures

/// @brief Saved tool output in a folder
public struct PackageFixtures: Sendable {

    /// The folder
    public let folder: URL

    /// @brief The Fixtures folder beside a test file.
    /// @param file The test file; the caller's by default
    /// @return The fixtures
    public init(beside file: String = #filePath) {
        folder = URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    /// @brief A fixture's bytes.
    /// @param name The file's name
    /// @return Its contents
    public func data(_ name: String) throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent(name))
    }

    /// @brief A fixture's text.
    /// @param name The file's name
    /// @return Its contents
    public func text(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    /// @brief A fixture's JSON object.
    /// @param name The file's name
    /// @return The object
    public func object(_ name: String) throws -> [String: Any] {
        try PackageJSON.object(data(name), name: name)
    }
}

// MARK: - Tool Runner

/// @brief Answers tool commands with saved output
public final class FakePackageToolRunner: PackageToolRunner, @unchecked Sendable {

    /// Tools that are "installed"
    public var installed: Set<String>

    /// Output by command line, "swift package dump-package"
    public var outputs: [String: PackageToolResult] = [:]

    /// The command lines run, in order, with their folders
    public var commands: [(line: String, folder: URL)] {
        lock.withLock { storedCommands }
    }

    private var storedCommands: [(line: String, folder: URL)] = []
    private let lock = NSLock()

    /// @brief A runner.
    /// @param installed The tools it finds
    /// @return The runner
    public init(installed: Set<String> = ["swift", "cargo", "npm"]) {
        self.installed = installed
    }

    /// @brief Answers a command with output.
    /// @param line The command line
    /// @param data Its standard output
    /// @param status Its exit status
    /// @param error Its standard error
    /// @return None
    public func answer(_ line: String, with data: Data, status: Int32 = 0, error: String = "") {
        lock.withLock {
            outputs[line] = PackageToolResult(status: status, output: data, errorText: error)
        }
    }

    public func find(_ tool: String) -> URL? {
        lock.withLock { installed.contains(tool) } ? URL(fileURLWithPath: "/usr/bin/\(tool)") : nil
    }

    public func run(_ tool: String, arguments: [String], in folder: URL) throws -> PackageToolResult {
        let line = ([tool] + arguments).joined(separator: " ")
        let (isInstalled, output) = lock.withLock { () -> (Bool, PackageToolResult?) in
            guard installed.contains(tool) else { return (false, nil) }
            storedCommands.append((line, folder))
            return (true, outputs[line])
        }
        guard isInstalled else {
            throw PackageError.toolMissing(tool)
        }
        return output ?? PackageToolResult(status: 1, output: Data(), errorText: "no answer for \(line)")
    }
}

// MARK: - Temporary Folders

/// @brief A temporary folder, removed by remove()
public struct PackageTempFolder: Sendable {

    /// The folder
    public let url: URL

    /// @brief Makes the folder.
    /// @return The folder
    public init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// @brief Writes a file under the folder, making its folders.
    /// @param path The path under the folder
    /// @param text Its contents
    /// @return The file's URL
    @discardableResult
    public func write(_ path: String, _ text: String) throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// @brief Removes the folder.
    /// @return None
    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - HTTP

/// @brief Answers a session's requests with the test's handlers.
public final class StubHTTPService: @unchecked Sendable {

    /// @brief A request the stub saw.
    public struct Request {
        public let method: String
        public let path: String
        public let headers: [String: String]
        public let url: URL?
    }

    /// @brief What a handler answers: a status and a JSON body, or an
    /// error to fail with.
    public enum Reply {
        case json(Int, Any)
        case failure(URLError.Code)
    }

    private static let header = "X-Test-Stub"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: StubHTTPService] = [:]

    let id = UUID().uuidString

    /// The session to give what is tested
    public let session: URLSession

    private var handlers: [String: (Request) -> Reply] = [:]
    private var seen: [Request] = []

    /// @brief A service with no handlers; requests to other paths get
    /// 404.
    /// @return The service
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTPProtocol.self]
        configuration.httpAdditionalHeaders = [Self.header: id]
        session = URLSession(configuration: configuration)
        Self.lock.withLock { Self.stubs[id] = self }
    }

    deinit {
        let id = self.id
        Self.lock.withLock { Self.stubs[id] = nil }
    }

    /// @brief Answers requests to a path, such as "/api/v1/crates".
    /// @param path The path
    /// @param handler Answers a request
    /// @return None
    public func on(_ path: String, _ handler: @escaping (Request) -> Reply) {
        Self.lock.withLock { handlers[path] = handler }
    }

    /// @brief The requests to a path.
    /// @param path The path
    /// @return The requests, in order
    public func requests(to path: String) -> [Request] {
        Self.lock.withLock { seen.filter { $0.path == path } }
    }

    fileprivate static func reply(to urlRequest: URLRequest) -> Reply {
        let stub = lock.withLock { urlRequest.value(forHTTPHeaderField: header).flatMap { stubs[$0] } }
        guard let stub else {
            return .failure(.cannotConnectToHost)
        }
        let request = Request(method: urlRequest.httpMethod ?? "GET", path: urlRequest.url?.path ?? "", headers: urlRequest.allHTTPHeaderFields ?? [:], url: urlRequest.url)
        let handler = lock.withLock { () -> ((Request) -> Reply)? in
            stub.seen.append(request)
            return stub.handlers[request.path]
        }
        return handler?(request) ?? .json(404, ["error": "not_found"])
    }
}

/// @brief The URL protocol StubHTTPService's sessions use.
final class StubHTTPProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        switch StubHTTPService.reply(to: request) {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .json(let status, let object):
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
