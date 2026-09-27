// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

enum AxolotyZenohLiveIntegrationError: Error, LocalizedError, Sendable {
    case commandFailed(String, Int32, String)
    case invalidOutput(String)
    case invalidArchive(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status, output):
            "\(command) exited with status \(status): \(output)"
        case let .invalidOutput(message), let .invalidArchive(message): message
        }
    }
}

/// Owns the opt-in live Zenoh test lifecycle inside the pinned project container.
struct AxolotyZenohLiveIntegration {
    private static let routerArchive = "zenoh-1.10.0-x86_64-unknown-linux-gnu-standalone.zip"
    private static let routerChecksum = "43de097382e3db4f95903cbadbbf472a21fbea53d6a3193606ae12b034a20881"
    private static let cArchive = "zenoh-c-1.10.0-x86_64-unknown-linux-gnu-standalone.zip"
    private static let cChecksum = "1168b3dffa7f4f48ffabfd640a3878ec0527c0a612ce825aa6f93e2cd05762d1"

    private let environment: [String: String]
    private let root: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        root = URL(fileURLWithPath: environment["WORKDIR"] ?? FileManager.default.currentDirectoryPath)
            .standardizedFileURL
    }

    func run() -> AxolotyCommandResult {
        do {
            try execute()
            return AxolotyCommandResult(standardOutput: "PASS: live Zenoh integration scenarios completed\n")
        } catch {
            return AxolotyCommandResult(
                standardError: "FAIL: live Zenoh integration: \(error.localizedDescription)\n",
                exitCode: 1
            )
        }
    }

    private func execute() throws(AxolotyZenohLiveIntegrationError) {
        guard AxolotyCheckPlan.currentPlatform == .linux else {
            throw .invalidOutput("the pinned zenoh-live tier requires Linux")
        }
        let cacheRoot = root.appending(path: ".build/zenoh-live/dependencies")
        let scratch = root.appending(path: ".build/zenoh-live/runs/run-\(UUID().uuidString.lowercased())")
        let routerRoot = cacheRoot.appending(path: "router")
        let cRoot = cacheRoot.appending(path: "zenoh-c")
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: routerRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: cRoot, withIntermediateDirectories: true)
        } catch {
            throw .invalidOutput("cannot create live Zenoh scratch directory: \(error.localizedDescription)")
        }

        let release = "https://github.com/eclipse-zenoh/zenoh/releases/download/1.10.0"
        try provision(Self.routerArchive, checksum: Self.routerChecksum, release: release, in: routerRoot)
        try provision(
            Self.cArchive,
            checksum: Self.cChecksum,
            release: "https://github.com/eclipse-zenoh/zenoh-c/releases/download/1.10.0",
            in: cRoot
        )

        let routerBinary = try requireFile(named: "zenohd", under: routerRoot.appending(path: "unpacked"))
        try runCommand("chmod", arguments: ["u+x", routerBinary.path])
        guard fileManager.isExecutableFile(atPath: routerBinary.path) else {
            throw .invalidArchive("zenohd from the pinned archive could not be made executable")
        }
        let pkgConfig = try requireFile(named: "zenohc.pc", under: cRoot.appending(path: "unpacked"))
        let zenohCRoot = pkgConfig.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try rewritePkgConfig(at: pkgConfig, prefix: zenohCRoot.path)
        let port = try availablePort()
        let endpoint = "tcp/127.0.0.1:\(port)"
        let routerLog = scratch.appending(path: "zenohd.log")
        let routerLogFile = try createFile(at: routerLog)
        let routerOutput: FileHandle
        do {
            routerOutput = try FileHandle(forWritingTo: routerLogFile)
        } catch {
            throw .invalidOutput("cannot open router log: \(error.localizedDescription)")
        }
        let router = Process()
        router.executableURL = routerBinary
        router.arguments = ["-l", endpoint]
        router.standardOutput = routerOutput
        router.standardError = routerOutput
        do {
            try router.run()
        } catch {
            throw .invalidOutput("cannot start pinned zenohd: \(error.localizedDescription)")
        }
        defer {
            if router.isRunning { router.terminate() }
            router.waitUntilExit()
            try? routerOutput.close()
        }

        try waitForRouter(process: router, port: port)
        print("ZENOH_LIVE_ROUTER_READY version=1.10.0 endpoint=\(endpoint)")
        let pkgConfigDirectory = pkgConfig.deletingLastPathComponent()
        let libraryDirectory = zenohCRoot.appending(path: "lib").path
        var childEnvironment = environment
        childEnvironment["AXOLOTY_ZENOH_LIVE_ENDPOINT"] = endpoint
        childEnvironment["AXOLOTY_ZENOH_LIVE_ROUTER_PID"] = String(router.processIdentifier)
        childEnvironment["AXOLOTY_ZENOH_LIVE_ROUTER"] = routerBinary.path
        childEnvironment["AXOLOTY_ZENOH_LIVE_C_PEER"] = scratch.appending(path: "zenoh-live-peer").path
        childEnvironment["PKG_CONFIG_PATH"] = [pkgConfigDirectory.path, environment["PKG_CONFIG_PATH"]]
            .compactMap { $0 }.joined(separator: ":")
        childEnvironment["LD_LIBRARY_PATH"] = [libraryDirectory, environment["LD_LIBRARY_PATH"]]
            .compactMap { $0 }.joined(separator: ":")

        let compilerFlags = try runCommand("pkg-config", arguments: ["--cflags", "--libs", "zenohc"], environment: childEnvironment)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        let cPeer = URL(fileURLWithPath: childEnvironment["AXOLOTY_ZENOH_LIVE_C_PEER"]!)
        try runCommand(
            "clang",
            arguments: ["-std=c11", "-D_POSIX_C_SOURCE=200809L", root.appending(path: "Packages/AxolotyZenoh/Tests/zenoh-live-peer.c").path, "-o", cPeer.path] + compilerFlags,
            environment: childEnvironment
        )
        defer { try? fileManager.removeItem(at: cPeer) }

        try runCommand(
            "swift",
            arguments: [
                "test", "--package-path", "Packages/AxolotyZenoh",
                "--scratch-path", ".build/zenoh-live/swift",
                "--cache-path", ".swiftpm-cache", "--disable-automatic-resolution",
                "--filter", "ZenohLiveIntegrationTests",
            ],
            environment: childEnvironment,
            streamsOutput: true
        )
    }

    private func provision(
        _ archive: String,
        checksum: String,
        release: String,
        in directory: URL
    ) throws(AxolotyZenohLiveIntegrationError) {
        let archiveURL = directory.appending(path: archive)
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            let priorDigest = (try? runCommand("sha256sum", arguments: [archiveURL.path])) ?? ""
            if priorDigest.split(whereSeparator: \.isWhitespace).first.map(String.init) != checksum {
                try? FileManager.default.removeItem(at: archiveURL)
            }
        }
        if !FileManager.default.fileExists(atPath: archiveURL.path) {
            try runCommand("curl", arguments: ["--fail", "--location", "--retry", "3", "--output", archiveURL.path, "\(release)/\(archive)"])
        }
        let verified = (try? runCommand("sha256sum", arguments: [archiveURL.path])) ?? ""
        guard verified.split(whereSeparator: \.isWhitespace).first.map(String.init) == checksum else {
            try? FileManager.default.removeItem(at: archiveURL)
            throw .invalidArchive("SHA-256 mismatch for pinned archive \(archive)")
        }
        let unpacked = directory.appending(path: "unpacked")
        if !FileManager.default.fileExists(atPath: unpacked.path) {
            try runCommand("unzip", arguments: ["-q", "-o", archiveURL.path, "-d", unpacked.path])
        }
    }

    private func requireFile(
        named name: String,
        under directory: URL,
        executable: Bool = false
    ) throws(AxolotyZenohLiveIntegrationError) -> URL {
        let output = try runCommand("find", arguments: [directory.path, "-type", "f", "-name", name, "-print", "-quit"])
        guard let first = output.split(whereSeparator: \.isNewline).first else {
            throw .invalidArchive("pinned archive is missing \(name)")
        }
        let url = URL(fileURLWithPath: String(first))
        guard !executable || FileManager.default.isExecutableFile(atPath: url.path) else {
            throw .invalidArchive("\(name) from the pinned archive is not executable")
        }
        return url
    }

    private func rewritePkgConfig(at file: URL, prefix: String) throws(AxolotyZenohLiveIntegrationError) {
        do {
            let original = try String(contentsOf: file, encoding: .utf8)
            let updated = original.replacingOccurrences(of: "prefix=/usr/local", with: "prefix=\(prefix)")
            try updated.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw .invalidArchive("cannot rewrite zenohc.pc: \(error.localizedDescription)")
        }
    }

    private func availablePort() throws(AxolotyZenohLiveIntegrationError) -> String {
        let output = try runCommand("python3", arguments: [
            "-c", "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()",
        ])
        guard let port = output.split(whereSeparator: \.isNewline).first else {
            throw .invalidOutput("cannot allocate a unique local Zenoh port")
        }
        return String(port)
    }

    private func waitForRouter(process: Process, port: String) throws(AxolotyZenohLiveIntegrationError) {
        for _ in 0..<100 {
            guard process.isRunning else { throw .invalidOutput("zenohd exited before router readiness") }
            let result = try? runCommand("python3", arguments: [
                "-c", "import socket,sys; s=socket.socket(); s.settimeout(.1); r=s.connect_ex(('127.0.0.1',int(sys.argv[1]))); s.close(); raise SystemExit(r)", port,
            ])
            if result != nil { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw .invalidOutput("zenohd readiness deadline expired")
    }

    private func createFile(at url: URL) throws(AxolotyZenohLiveIntegrationError) -> URL {
        let created = FileManager.default.createFile(atPath: url.path, contents: nil)
        guard created || FileManager.default.fileExists(atPath: url.path) else {
            throw .invalidOutput("cannot create router log at \(url.path)")
        }
        return url
    }

    @discardableResult
    private func runCommand(
        _ executable: String,
        arguments: [String],
        environment childEnvironment: [String: String]? = nil,
        streamsOutput: Bool = false
    ) throws(AxolotyZenohLiveIntegrationError) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.environment = childEnvironment ?? environment
        let output: Pipe?
        if streamsOutput {
            output = nil
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        } else {
            let pipe = Pipe()
            output = pipe
            process.standardOutput = pipe
            process.standardError = pipe
        }
        do {
            try process.run()
        } catch {
            throw .invalidOutput("cannot run \(executable): \(error.localizedDescription)")
        }
        let data = output?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw .commandFailed(([executable] + arguments).joined(separator: " "), process.terminationStatus, text)
        }
        return text
    }
}
