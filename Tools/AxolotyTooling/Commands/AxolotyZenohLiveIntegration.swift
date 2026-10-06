// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Owns the opt-in live Zenoh test lifecycle inside the pinned project container
/// on Linux or with the native toolchain on macOS.
struct AxolotyZenohLiveIntegration {
    private let environment: [String: String]
    private let root: URL
    private let toolchain: AxolotyZenohToolchain

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        toolchain = AxolotyZenohToolchain(environment: environment)
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

    private func execute() throws(AxolotyZenohCommandError) {
        try toolchain.requireSupportedHost(for: "zenoh-live")
        let cacheRoot = root.appending(path: ".build/zenoh-live/dependencies")
        let scratch = root.appending(path: ".build/zenoh-live/runs/run-\(UUID().uuidString.lowercased())")
        let fileManager = FileManager.default
        try toolchain.createDirectory(scratch)
        let routerBinary = try toolchain.provisionRouter(in: cacheRoot.appending(path: "router"))
        let zenohC = try toolchain.provisionZenohC(in: cacheRoot.appending(path: "zenoh-c"))
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
        FileHandle.standardError.write(Data("ZENOH_LIVE_ROUTER_READY version=1.10.0 endpoint=\(endpoint)\n".utf8))
        var childEnvironment = zenohC.environment(extending: environment)
        childEnvironment["AXOLOTY_ZENOH_LIVE_ENDPOINT"] = endpoint
        childEnvironment["AXOLOTY_ZENOH_LIVE_ROUTER_PID"] = String(router.processIdentifier)
        childEnvironment["AXOLOTY_ZENOH_LIVE_ROUTER"] = routerBinary.path
        childEnvironment["AXOLOTY_ZENOH_LIVE_C_PEER"] = scratch.appending(path: "zenoh-live-peer").path

        let compilerFlags = zenohC.cCompilerArguments
        let cPeer = URL(fileURLWithPath: childEnvironment["AXOLOTY_ZENOH_LIVE_C_PEER"]!)
        try toolchain.runCommand(
            "clang",
            arguments: ["-std=c11", "-D_POSIX_C_SOURCE=200809L", root.appending(path: "Packages/AxolotyZenoh/Tests/zenoh-live-peer.c").path, "-o", cPeer.path] + compilerFlags,
            environment: childEnvironment
        )
        defer { try? fileManager.removeItem(at: cPeer) }

        try toolchain.runCommand(
            "swift",
            arguments: [
                "test", "--package-path", "Packages/AxolotyZenoh",
                "--scratch-path", ".build/zenoh-live/swift",
                "--cache-path", ".swiftpm-cache", "--disable-automatic-resolution",
                "--filter", "ZenohLiveIntegrationTests",
            ] + zenohC.swiftLinkerArguments,
            environment: childEnvironment,
            streamsOutput: true
        )
    }

    private func availablePort() throws(AxolotyZenohCommandError) -> String {
        let output = try toolchain.runCommand("python3", arguments: [
            "-c", "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()",
        ])
        guard let port = output.split(whereSeparator: \.isNewline).first else {
            throw .invalidOutput("cannot allocate a unique local Zenoh port")
        }
        return String(port)
    }

    private func waitForRouter(process: Process, port: String) throws(AxolotyZenohCommandError) {
        for _ in 0..<100 {
            guard process.isRunning else { throw .invalidOutput("zenohd exited before router readiness") }
            let result = try? toolchain.runCommand("python3", arguments: [
                "-c", "import socket,sys; s=socket.socket(); s.settimeout(.1); r=s.connect_ex(('127.0.0.1',int(sys.argv[1]))); s.close(); raise SystemExit(r)", port,
            ])
            if result != nil { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw .invalidOutput("zenohd readiness deadline expired")
    }

    private func createFile(at url: URL) throws(AxolotyZenohCommandError) -> URL {
        let created = FileManager.default.createFile(atPath: url.path, contents: nil)
        guard created || FileManager.default.fileExists(atPath: url.path) else {
            throw .invalidOutput("cannot create router log at \(url.path)")
        }
        return url
    }
}
