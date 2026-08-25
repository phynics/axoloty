// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Runs the broker-backed integration contract with bounded broker lifecycle.
public protocol AxolotyIntegrationRunning: Sendable {
    /// Starts a local broker, runs integration tests, and stops the broker.
    func run() -> AxolotyCheckCommandResult
}

/// An integration runner that can enforce the enclosing check-plan budget.
///
/// The compatibility ``AxolotyIntegrationRunning`` protocol remains available
/// for test doubles and older callers. Canonical plan execution uses this
/// refinement when available so broker readiness and transport execution share
/// one remaining deadline.
public protocol AxolotyBoundedIntegrationRunning: AxolotyIntegrationRunning {
    /// Runs integration checks with an optional enclosing deadline.
    ///
    /// - Parameter timeoutSeconds: Remaining plan budget, or `nil` when the
    ///   caller is not executing inside a bounded plan.
    /// - Returns: The bounded integration result.
    func run(timeoutSeconds: TimeInterval?) -> AxolotyCheckCommandResult
}

/// Foundation implementation of the local-broker integration lifecycle.
public struct FoundationIntegrationRunner: AxolotyBoundedIntegrationRunning {
    static let brokerProbeCommand = AxolotyCommandPlan(
        executable: "node",
        arguments: ["-e", """
        const net=require('node:net');
        const socket=net.createConnection({host:'127.0.0.1',port:1883},()=>{socket.end();process.exit(0)});
        socket.setTimeout(400,()=>{socket.destroy();process.exit(1)});
        socket.on('error',()=>process.exit(1));
        """],
        timeoutSeconds: 5
    )
    static var testCommand: AxolotyCommandPlan? {
        try? AxolotyCanonicalTestManifest.loadDefault()
            .node(named: "integration-tests")
            .checkNode()
            .command
    }

    static var commandPlans: [AxolotyCommandPlan] {
        [brokerProbeCommand, testCommand].compactMap { $0 }
    }

    private let commandRunner: any AxolotyCheckCommandRunning
    private let contextValidator: AxolotyExecutionContextValidator
    private let clock: any AxolotyTimingClock

    /// Creates an integration runner.
    ///
    /// - Parameter commandRunner: Runner used for readiness and Swift tests.
    public init(commandRunner: any AxolotyCheckCommandRunning = FoundationCommandRunner()) {
        self.init(
            commandRunner: commandRunner,
            contextValidator: AxolotyExecutionContextValidator()
        )
    }

    init(
        commandRunner: any AxolotyCheckCommandRunning,
        contextValidator: AxolotyExecutionContextValidator,
        clock: any AxolotyTimingClock = AxolotyContinuousTimingClock()
    ) {
        self.commandRunner = commandRunner
        self.contextValidator = contextValidator
        self.clock = clock
    }

    /// Starts Mosquitto, waits for bounded readiness, runs tests, and stops it.
    public func run() -> AxolotyCheckCommandResult {
        run(timeoutSeconds: nil)
    }

    /// Starts Mosquitto, waits for bounded readiness, runs tests, and stops it
    /// without exceeding the enclosing canonical plan budget.
    ///
    /// - Parameter timeoutSeconds: Remaining plan budget, or `nil` for the
    ///   ordinary standalone integration command.
    /// - Returns: The integration result, including a timeout diagnostic when
    ///   the enclosing budget expires during setup or execution.
    public func run(timeoutSeconds: TimeInterval?) -> AxolotyCheckCommandResult {
        guard timeoutSeconds.map({ $0.isFinite && $0 > 0 }) ?? true else {
            return AxolotyCheckCommandResult(
                exitCode: 64,
                standardError: "invalid integration deadline: timeoutSeconds must be positive\n"
            )
        }
        let startedAt = clock.now()
        let deadline = timeoutSeconds.map { startedAt + $0 }
        guard let testCommand = Self.testCommand else {
            return AxolotyCheckCommandResult(
                exitCode: 70,
                standardError: "canonical integration test node is unavailable"
            )
        }
        if let failure = contextValidator.failureResult(validating: Self.commandPlans) {
            return failure
        }
        guard !isExpired(deadline), !probeBroker(deadline: deadline) else {
            if isExpired(deadline) {
                return deadlineResult(startedAt: startedAt, deadline: deadline, phase: "broker-probe")
            }
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
            let clock = ContinuousClock()
            let reapDeadline = clock.now.advanced(by: .seconds(2))
            while broker.isRunning && clock.now < reapDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if broker.isRunning {
                _ = kill(broker.processIdentifier, SIGKILL)
                let killDeadline = clock.now.advanced(by: .seconds(2))
                while broker.isRunning && clock.now < killDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            try? logHandle.close()
            try? FileManager.default.removeItem(at: artifacts)
        }

        guard waitForBroker(process: broker, deadline: deadline) else {
            if isExpired(deadline) {
                return deadlineResult(startedAt: startedAt, deadline: deadline, phase: "broker-readiness")
            }
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
        guard let testCommand = commandBoundedByDeadline(testCommand, deadline: deadline) else {
            return deadlineResult(startedAt: startedAt, deadline: deadline, phase: "integration-test")
        }
        return commandRunner.run(testCommand)
    }

    private func waitForBroker(process: Process, deadline: TimeInterval?) -> Bool {
        let readinessDeadline = deadline ?? (clock.now() + 5)
        while clock.now() < readinessDeadline {
            guard process.isRunning else { return false }
            if probeBroker(deadline: readinessDeadline) { return true }
            Thread.sleep(forTimeInterval: min(0.5, max(0.01, readinessDeadline - clock.now())))
        }
        return false
    }

    private func probeBroker(deadline: TimeInterval?) -> Bool {
        guard let command = commandBoundedByDeadline(Self.brokerProbeCommand, deadline: deadline) else {
            return false
        }
        return commandRunner.run(command).exitCode == 0
    }

    private func commandBoundedByDeadline(
        _ command: AxolotyCommandPlan,
        deadline: TimeInterval?
    ) -> AxolotyCommandPlan? {
        guard let deadline else { return command }
        let remaining = deadline - clock.now()
        guard remaining > 0 else { return nil }
        return AxolotyCommandPlan(
            executable: command.executable,
            arguments: command.arguments,
            environment: command.environment,
            executionContext: command.executionContext,
            timeoutSeconds: min(command.timeoutSeconds ?? remaining, remaining)
        )
    }

    private func isExpired(_ deadline: TimeInterval?) -> Bool {
        guard let deadline else { return false }
        return clock.now() >= deadline
    }

    private func deadlineResult(
        startedAt: TimeInterval,
        deadline: TimeInterval?,
        phase: String
    ) -> AxolotyCheckCommandResult {
        let budget = deadline.map { $0 - startedAt } ?? 0
        let elapsed = clock.now() - startedAt
        return AxolotyCheckCommandResult(
            exitCode: 124,
            standardError: String(
                format: "integration plan deadline exceeded: phase=%@ elapsed=%.3fs budget=%.3fs\n",
                locale: Locale(identifier: "en_US_POSIX"),
                phase,
                elapsed,
                budget
            )
        )
    }
}
