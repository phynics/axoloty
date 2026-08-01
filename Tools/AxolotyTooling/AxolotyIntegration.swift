// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Runs the broker-backed integration contract with bounded broker lifecycle.
public protocol AxolotyIntegrationRunning: Sendable {
    /// Starts a local broker, runs integration tests, and stops the broker.
    func run() -> AxolotyCheckCommandResult
}

/// Foundation implementation of the local-broker integration lifecycle.
public struct FoundationIntegrationRunner: AxolotyIntegrationRunning {
    private let commandRunner: any AxolotyCheckCommandRunning

    /// Creates an integration runner.
    ///
    /// - Parameter commandRunner: Runner used for readiness and Swift tests.
    public init(commandRunner: any AxolotyCheckCommandRunning = FoundationCommandRunner()) {
        self.commandRunner = commandRunner
    }

    /// Starts Mosquitto, waits for bounded readiness, runs tests, and stops it.
    public func run() -> AxolotyCheckCommandResult {
        guard !probeBroker() else {
            return AxolotyCheckCommandResult(
                exitCode: 1,
                standardError: "port 1883 is already owned by another broker"
            )
        }
        let artifacts = FileManager.default.temporaryDirectory
            .appending(path: "axoloty-tool-integration-\(UUID().uuidString)", directoryHint: .isDirectory)
        let configuration = artifacts.appending(path: "mosquitto.conf")
        let log = artifacts.appending(path: "mosquitto.log")
        do {
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            try "listener 1883 127.0.0.1\nallow_anonymous true\n".write(
                to: configuration,
                atomically: true,
                encoding: .utf8
            )
            _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        } catch {
            return AxolotyCheckCommandResult(
                exitCode: 70,
                standardError: "unable to prepare local Mosquitto: \(error.localizedDescription)"
            )
        }
        guard let logHandle = try? FileHandle(forWritingTo: log) else {
            return AxolotyCheckCommandResult(exitCode: 70, standardError: "unable to create Mosquitto log")
        }
        let broker = Process()
        broker.executableURL = URL(filePath: "/usr/bin/env")
        broker.arguments = ["mosquitto", "-c", configuration.path]
        broker.standardOutput = logHandle
        broker.standardError = logHandle
        do {
            try broker.run()
        } catch {
            try? logHandle.close()
            try? FileManager.default.removeItem(at: artifacts)
            return AxolotyCheckCommandResult(
                exitCode: 70,
                standardError: "unable to start local Mosquitto: \(error.localizedDescription)"
            )
        }
        defer {
            if broker.isRunning { broker.terminate() }
            broker.waitUntilExit()
            try? logHandle.close()
            try? FileManager.default.removeItem(at: artifacts)
        }

        guard waitForBroker(process: broker) else {
            try? logHandle.synchronize()
            let diagnostics = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return AxolotyCheckCommandResult(
                exitCode: 1,
                standardError: (broker.isRunning
                    ? "local Mosquitto did not become ready within 5 seconds"
                    : "local Mosquitto exited before becoming ready")
                    + (diagnostics.isEmpty ? "" : "\n\(diagnostics)")
            )
        }
        return commandRunner.run(AxolotyCommandPlan(
            executable: "swift",
            arguments: [
                "test", "--cache-path", ".swiftpm-cache", "--disable-automatic-resolution",
                "--filter",
                "CommunicationSubscriptionCoordinatorTests|BroadcastTransportTests|MQTTNIOClientTests|DecentralizedLoggingTest|ObjectLifecycleControllerTests|InspectorBrokerIntegrationTests",
            ],
            environment: ["AXOLOTY_INSPECTOR_LIVE": "1"]
        ))
    }

    private func waitForBroker(process: Process) -> Bool {
        for _ in 0..<10 {
            guard process.isRunning else { return false }
            if probeBroker() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func probeBroker() -> Bool {
        let probe = """
        const net=require('node:net');
        const socket=net.createConnection({host:'127.0.0.1',port:1883},()=>{socket.end();process.exit(0)});
        socket.setTimeout(400,()=>{socket.destroy();process.exit(1)});
        socket.on('error',()=>process.exit(1));
        """
        return commandRunner.run(AxolotyCommandPlan(executable: "node", arguments: ["-e", probe])).exitCode == 0
    }
}
