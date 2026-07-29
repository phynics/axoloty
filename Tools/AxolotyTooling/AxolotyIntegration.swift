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
        let broker = Process()
        broker.executableURL = URL(filePath: "/usr/bin/env")
        broker.arguments = ["mosquitto", "-c", "/etc/mosquitto/conf.d/coatyswift.conf"]
        broker.standardOutput = FileHandle.nullDevice
        broker.standardError = FileHandle.nullDevice
        do {
            try broker.run()
        } catch {
            return AxolotyCheckCommandResult(
                exitCode: 70,
                standardError: "unable to start local Mosquitto: \(error.localizedDescription)"
            )
        }
        defer {
            if broker.isRunning {
                broker.terminate()
                broker.waitUntilExit()
            }
        }

        guard waitForBroker() else {
            return AxolotyCheckCommandResult(
                exitCode: 1,
                standardError: "local Mosquitto did not become ready within 5 seconds"
            )
        }
        return commandRunner.run(AxolotyCommandPlan(
            executable: "swift",
            arguments: [
                "test", "--cache-path", ".swiftpm-cache", "--disable-automatic-resolution",
                "--filter",
                "CommunicationSubscriptionCoordinatorTests|BroadcastTransportTests|MQTTNIOClientTests|DecentralizedLoggingTest|ObjectLifecycleControllerTests",
            ]
        ))
    }

    private func waitForBroker() -> Bool {
        let probe = """
        const net=require('node:net');
        const socket=net.createConnection({host:'127.0.0.1',port:1883},()=>{socket.end();process.exit(0)});
        socket.setTimeout(400,()=>{socket.destroy();process.exit(1)});
        socket.on('error',()=>process.exit(1));
        """
        for _ in 0..<10 {
            if commandRunner.run(AxolotyCommandPlan(executable: "node", arguments: ["-e", probe])).exitCode == 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}
