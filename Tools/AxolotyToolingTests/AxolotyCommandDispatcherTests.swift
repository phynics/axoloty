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
        "wire-dependencies", "wire-independent-resolution", "support-wire-dependencies",
        "support-wire-resolution", "support-wire-isolation", "support-benchmark-corpus",
        "support-benchmark-size", "support-benchmark-wire", "support-benchmark-bounds",
        "support-budget-manifest", "support-container", "support-fuzz-runner",
        "support-node-tests", "support-tier-contract", "support-embedded-compile",
        "support-embedded-smoke", "embedded-build", "embedded-linker",
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
    let manifest = try JSONDecoder().decode(AxolotyCheckManifest.self, from: Data(result.standardOutput.utf8))

    #expect(result.exitCode == 0)
    #expect(manifest.schemaVersion == 1)
    #expect(manifest.results.map(\.name) == ["resolve", "build", "test-ax", "test-wire"])
}

@Test
func testOfflineUsesTheCheckPlan() throws {
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        fileSystem: StubFileSystem(paths: []),
        environment: [:]
    )

    let result = dispatcher.run(arguments: ["test", "offline"])
    let manifest = try JSONDecoder().decode(AxolotyCheckManifest.self, from: Data(result.standardOutput.utf8))

    #expect(result.exitCode == 0)
    #expect(manifest.results.map(\.name) == AxolotyCheckPlan.initialOffline.nodes.map(\.name))
}

@Test
func releaseSnapshotsGenerateThenVerifyConfiguredBundle() throws {
    let runner = RecordingSequenceRunner()
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: runner,
        fileSystem: StubFileSystem(paths: []),
        environment: [
            "AXOLOTY_SNAPSHOT_SOURCE": "fixtures",
            "AXOLOTY_SNAPSHOT_OUTPUT": "artifacts",
            "AXOLOTY_IMAGE_IDENTITY": "sha256:test",
            "AXOLOTY_GIT_COMMIT": "abc123",
            "AXOLOTY_GIT_CLEAN": "true",
        ]
    )

    let result = dispatcher.run(arguments: ["release", "snapshots"])
    let manifest = try JSONDecoder().decode(AxolotyCheckManifest.self, from: Data(result.standardOutput.utf8))

    #expect(result.exitCode == 0)
    #expect(manifest.results.map(\.name) == ["release-snapshots-generate", "release-snapshots-verify"])
    #expect(runner.commands.map(\.arguments) == [
        ["Tests/Support/release-snapshots.mjs", "generate", "fixtures", "artifacts"],
        ["Tests/Support/release-snapshots.mjs", "verify", "artifacts"],
    ])
    #expect(runner.commands.first?.environment["AXOLOTY_IMAGE_IDENTITY"] == "sha256:test")
    #expect(runner.commands.first?.environment["AXOLOTY_GIT_COMMIT"] == "abc123")
}

private final class RecordingSequenceRunner: AxolotyCheckCommandRunning, @unchecked Sendable {
    var commands: [AxolotyCommandPlan] = []
    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        commands.append(command)
        return AxolotyCheckCommandResult(exitCode: 0)
    }
}
