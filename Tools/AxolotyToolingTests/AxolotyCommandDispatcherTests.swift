// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyTooling
import Foundation
import Testing

private struct StubFileSystem: AxolotyFileSystem {
    let paths: Set<String>
    func exists(atPath path: String) -> Bool { paths.contains(path) }
}

private struct StubRunner: AxolotyCheckCommandRunning {
    let result: AxolotyCheckCommandResult
    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult { result }
}

private final class RecordingRunner: AxolotyCheckCommandRunning, @unchecked Sendable {
    var command: AxolotyCommandPlan?
    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        self.command = command
        return AxolotyCheckCommandResult(exitCode: 0)
    }
}

@Test
func helpCommandPrintsUsage() {
    let result = AxolotyCommandDispatcher().run(arguments: ["help"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.contains("Usage: ax <command>"))
    #expect(result.standardError.isEmpty)
}

@Test
func versionCommandPrintsVersion() {
    let result = AxolotyCommandDispatcher().run(arguments: ["--version"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "ax 0.1.0")
    #expect(result.standardError.isEmpty)
}

@Test
func checkPlanPrintsStableJSON() {
    let result = AxolotyCommandDispatcher().run(arguments: ["check", "--plan"])

    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)
    let plan = try? JSONDecoder().decode(AxolotyCheckPlan.self, from: Data(result.standardOutput.utf8))
    #expect(plan?.nodes.map(\.name) == [
        "resolve", "build", "lint", "test-ax", "test-unit", "test-module",
        "test-fuzz", "test-wire", "no-anycodable", "no-foundation-wire",
        "wire-dependencies", "wire-independent-resolution", "embedded-build",
        "embedded-linker",
    ])
}

@Test
func optionalHardwareCheckSkipsAbsentDevice() throws {
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        fileSystem: StubFileSystem(paths: []),
        environment: [:]
    )
    let result = dispatcher.run(arguments: ["hardware", "check"])
    let outcome = try JSONDecoder().decode(AxolotyHardwareOutcome.self, from: Data(result.standardOutput.utf8))
    #expect(result.exitCode == 0)
    #expect(outcome == AxolotyHardwareOutcome(status: .skipped, device: "/dev/ttyACM0", reason: "device is not present"))
}

@Test
func requiredHardwareCheckFailsAbsentDevice() throws {
    let dispatcher = AxolotyCommandDispatcher(fileSystem: StubFileSystem(paths: []), environment: [:])
    let result = dispatcher.run(arguments: ["hardware", "require"])
    let outcome = try JSONDecoder().decode(AxolotyHardwareOutcome.self, from: Data(result.standardOutput.utf8))
    #expect(result.exitCode != 0)
    #expect(outcome.status == .failed)
}

@Test
func presentHardwareRunsSmokeCommand() throws {
    let runner = RecordingRunner()
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: runner,
        fileSystem: StubFileSystem(paths: ["/dev/test"]),
        environment: [:]
    )
    let result = dispatcher.run(arguments: ["hardware", "check", "--device", "/dev/test"])
    let outcome = try JSONDecoder().decode(AxolotyHardwareOutcome.self, from: Data(result.standardOutput.utf8))
    #expect(result.exitCode == 0)
    #expect(outcome.status == .passed)
    #expect(runner.command?.executable == "Tests/Support/embedded-swift-smoke.sh")
    #expect(runner.command?.environment["EMBEDDED_DEVICE"] == "/dev/test")
}

@Test
func wireVerifyRunsOnlyItsDependencyClosure() throws {
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        fileSystem: StubFileSystem(paths: []),
        environment: [:]
    )

    let result = dispatcher.run(arguments: ["wire", "verify"])
    let checks = try JSONDecoder().decode([AxolotyCheckResult].self, from: Data(result.standardOutput.utf8))

    #expect(result.exitCode == 0)
    #expect(checks.map(\.name) == ["resolve", "build", "test-ax", "test-wire"])
}

@Test
func testOfflineUsesTheCheckPlan() throws {
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        fileSystem: StubFileSystem(paths: []),
        environment: [:]
    )

    let result = dispatcher.run(arguments: ["test", "offline"])
    let checks = try JSONDecoder().decode([AxolotyCheckResult].self, from: Data(result.standardOutput.utf8))

    #expect(result.exitCode == 0)
    #expect(checks.map(\.name) == AxolotyCheckPlan.initialOffline.nodes.map(\.name))
}
