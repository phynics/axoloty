// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

private let projectEnvironment = ["AXOLOTY_DEVCONTAINER": "1"]
struct StubFileSystem: AxolotyFileSystem {
    let paths: Set<String>
    func exists(atPath path: String) -> Bool { paths.contains(path) }
}

private struct StubRunner: AxolotyCheckCommandRunning {
    let result: AxolotyCheckCommandResult
    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult { result }
}

private final class StubDeviceLease: AxolotyDeviceLease, @unchecked Sendable {}

private struct StubDeviceLeaseManager: AxolotyDeviceLeasing {
    let available: Bool
    func acquire(device: String) -> (any AxolotyDeviceLease)? {
        available ? StubDeviceLease() : nil
    }
}

private final class RecordingRunner: AxolotyCheckCommandRunning, @unchecked Sendable {
    var command: AxolotyCommandPlan?
    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        self.command = command
        return AxolotyCheckCommandResult(exitCode: 0)
    }
}

private final class RecordingFileSystem: AxolotyFileSystem, @unchecked Sendable {
    private(set) var checkedPaths: [String] = []

    func exists(atPath path: String) -> Bool {
        checkedPaths.append(path)
        return true
    }
}

private final class RecordingDeviceLeaseManager: AxolotyDeviceLeasing, @unchecked Sendable {
    private(set) var acquiredDevices: [String] = []

    func acquire(device: String) -> (any AxolotyDeviceLease)? {
        acquiredDevices.append(device)
        return StubDeviceLease()
    }
}

private final class RecordingIntegrationRunner: AxolotyIntegrationRunning, @unchecked Sendable {
    private(set) var runCount = 0

    func run() -> AxolotyCheckCommandResult {
        runCount += 1
        return AxolotyCheckCommandResult(exitCode: 0)
    }
}

private func decodeDiagnostic(_ result: AxolotyCommandResult) throws -> AxolotyExecutionContextDiagnostic {
    try JSONDecoder().decode(
        AxolotyExecutionContextDiagnostic.self,
        from: Data(result.standardError.utf8)
    )
}

@Test
func helpCommandPrintsUsage() {
    let result = AxolotyCommandDispatcher().run(arguments: ["help"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.contains("Usage: axoloty-tool <command>"))
    #expect(result.standardOutput.contains("test tooling"))
    #expect(result.standardError.isEmpty)
}

@Test
func invalidCommandUsesConfiguredExecutableNameInErrorAndUsage() {
    let dispatcher = AxolotyCommandDispatcher(executableName: "ax", environment: projectEnvironment)

    let result = dispatcher.run(arguments: ["unknown"])

    #expect(result.exitCode == 64)
    #expect(result.standardError.contains("unsupported ax command"))
    #expect(result.standardError.contains("Usage: ax <command>"))
    #expect(!result.standardError.contains("axoloty-tool"))
}

@Test
func versionCommandPrintsVersion() {
    let result = AxolotyCommandDispatcher().run(arguments: ["--version"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "axoloty-tool 0.2.0")
    #expect(result.standardError.isEmpty)
}

@Test
func checkPlanPrintsStableJSON() {
    let result = AxolotyCommandDispatcher().run(arguments: ["check", "--plan"])

    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)
    let plan = try? JSONDecoder().decode(AxolotyCheckPlan.self, from: Data(result.standardOutput.utf8))
    var expectedNames = [
        "resolve", "build", "lint", "test-tooling", "test-inspector-cli", "test-unit", "test-module",
        "test-fuzz", "test-wire", "no-anycodable", "no-foundation-wire",
        "wire-dependencies", "wire-independent-resolution", "wire-distribution", "support-wire-dependencies",
        "support-wire-resolution", "support-wire-isolation", "support-benchmark-corpus",
        "support-benchmark-size", "support-benchmark-wire", "support-benchmark-bounds",
        "support-budget-manifest", "support-node-tests", "support-tier-contract",
    ]
    #if os(Linux)
    expectedNames += [
        "support-container", "support-fuzz-runner", "support-embedded-compile",
        "support-embedded-smoke", "embedded-toolchain", "embedded-build", "embedded-linker",
    ]
    #endif
    #expect(plan?.nodes.map(\.name) == expectedNames)
    #expect(plan?.nodes.first(where: { $0.name == "lint" })?.command.arguments == [
        "lint", "--no-cache", "--config", ".swiftlint.yml",
    ])
    #expect(plan?.nodes.first(where: { $0.name == "test-tooling" })?.command.arguments == [
        "test", "-Xswiftc", "-warnings-as-errors", "--cache-path", ".swiftpm-cache",
        "--disable-automatic-resolution", "--filter",
        "AxolotyCommandDispatcherTests|AxolotyDeviceLeaseTests|AxolotyDevelopmentServiceTests|AxolotyMQTTServiceTests|AxolotyServeParserTests|AxolotyInspectorCoreTests|AxolotyInspectorRuntimeTests|AxolotyMCPTests",
    ])
    #expect(plan?.nodes.allSatisfy { timeout in
        guard let seconds = timeout.command.timeoutSeconds else { return false }
        return seconds.isFinite && seconds > 0
    } == true)
}

@Test
func canonicalManifestDefinesVerifyRootsAndBoundedTestOne() throws {
    let manifest = try AxolotyCanonicalTestManifest.loadDefault()
    #expect(manifest.schemaVersion == 2)
    #expect(manifest.requiredGates.allSatisfy { gate in manifest.nodes.contains { $0.id == gate } })
    #expect(manifest.ciRequiredGates.allSatisfy { gate in manifest.nodes.contains { $0.id == gate } })
    #expect(manifest.testOneCommand(filter: "suite;touch /tmp/injected").arguments.last == "suite;touch /tmp/injected")
    #expect(manifest.testOne.timeoutSeconds > 0)
}

@Test
func canonicalSwiftBuildsTreatWarningsAsErrors() throws {
    let manifest = try AxolotyCanonicalTestManifest.loadDefault()
    let compilingCommands = manifest.nodes
        .map(\.command)
        .filter { command in
            command.executable == "swift"
                && ["build", "test"].contains(command.arguments.first)
                && !command.arguments.contains("--skip-build")
        } + [manifest.testOne.command]

    #expect(!compilingCommands.isEmpty)
    for command in compilingCommands {
        #expect(command.arguments.contains("-Xswiftc"))
        #expect(command.arguments.contains("-warnings-as-errors"))
    }
}

@Test
func canonicalManifestErrorsHaveStableLocalizedDiagnostics() {
    let error = AxolotyCanonicalTestManifestError.decodingFailure(
        path: "/tmp/test-tiers.json",
        reason: "invalid JSON"
    )

    #expect(error.errorDescription == error.userFriendlyMessage)
    #expect(error.localizedDescription == error.userFriendlyMessage)
    #expect(error.userFriendlyMessage.contains("/tmp/test-tiers.json"))
}

@Test
func canonicalManifestUsesOverrideBeforeBundledOrRepositoryManifest() throws {
    let data = try JSONEncoder().encode(AxolotyCanonicalTestManifest.loadDefault())
    var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    document["manifestID"] = "axoloty-test-override"
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-manifest-\(UUID().uuidString)", directoryHint: .isDirectory)
    let override = directory.appending(path: "manifest.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: override)

    let manifest = try AxolotyCanonicalTestManifest.loadDefault(environment: [
        "AXOLOTY_TEST_MANIFEST": override.path,
    ])

    #expect(manifest.manifestID == "axoloty-test-override")
}

@Test
func verifyPlanIncludesStaticSupportWithoutRecursiveCoverageGate() throws {
    let manifest = try AxolotyCanonicalTestManifest.loadDefault()
    let ordinary = try manifest.plan(named: "verify")
    let ci = try manifest.plan(named: "verify", ci: true)
    #expect(ordinary.nodes.contains { $0.name == "support-tier-contract" })
    #expect(ordinary.nodes.contains { $0.name == "no-anycodable" })
    #expect(ordinary.nodes.contains { $0.name == "logging-global" })
    #expect(!ordinary.nodes.contains { $0.name == "coverage-check" })
    #expect(!ci.nodes.contains { $0.name == "coverage-check" })
}

@Test
func canonicalExecutorSerializesIndependentNodes() {
    let runner = RecordingSequenceRunner()
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: runner,
        fileSystem: StubFileSystem(paths: []),
        environment: projectEnvironment
    )

    let result = dispatcher.run(arguments: ["test", "offline"])

    #expect(result.exitCode == 0)
    #expect(runner.maxConcurrent == 1)
}

@Test
func explainIsMachineReadableAndHumanReadable() throws {
    let environment = projectEnvironment.merging(["AXOLOTY_OUTPUT": "human"]) { _, value in value }
    let dispatcher = AxolotyCommandDispatcher(environment: environment)
    let result = dispatcher.run(arguments: ["explain", "unit"])
    #expect(result.exitCode == 0)
    #expect(result.standardOutput.contains("PLAN unit"))
    #expect(result.standardOutput.contains("policy network=none"))
}

@Test
func humanCheckOutputUsesAReadableSummaryWithoutMachineManifest() {
    let environment = projectEnvironment.merging(["AXOLOTY_OUTPUT": "human"]) { _, value in value }
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        environment: environment
    )

    let result = dispatcher.run(arguments: ["test", "tooling"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.contains("PASSED resolve"))
    #expect(result.standardOutput.contains("PASSED test-tooling"))
    #expect(!result.standardOutput.contains("schemaVersion"))
}

@Test
func embeddedDoctorRunsDeviceIndependentEnvironmentCheck() {
    let runner = RecordingRunner()
    let dispatcher = AxolotyCommandDispatcher(commandRunner: runner, environment: projectEnvironment)

    let result = dispatcher.run(arguments: ["embedded", "doctor"])

    #expect(result.exitCode == 0)
    #expect(runner.command?.executable == "Tests/Support/check-embedded-environment.sh")
}

@Test
func checkPlanDisablesSwiftLintCache() throws {
    let plan = AxolotyCheckPlan.initialOffline(for: .linux)
    let lint = try #require(plan.nodes.first { $0.name == "lint" })

    #expect(lint.command.arguments == ["lint", "--no-cache", "--config", ".swiftlint.yml"])
}

@Test
func optionalHardwareCheckSkipsAbsentDevice() throws {
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        fileSystem: StubFileSystem(paths: []),
        environment: projectEnvironment
    )
    let result = dispatcher.run(arguments: ["hardware", "check"])
    let outcome = try JSONDecoder().decode(AxolotyHardwareOutcome.self, from: Data(result.standardOutput.utf8))
    #expect(result.exitCode == 0)
    #expect(outcome == AxolotyHardwareOutcome(status: .skipped, device: "/dev/ttyACM0", reason: "device is not present"))
}

@Test
func requiredHardwareCheckFailsAbsentDevice() throws {
    let dispatcher = AxolotyCommandDispatcher(fileSystem: StubFileSystem(paths: []), environment: projectEnvironment)
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
        environment: projectEnvironment
    )
    let result = dispatcher.run(arguments: ["hardware", "check", "--device", "/dev/test"])
    let outcome = try JSONDecoder().decode(AxolotyHardwareOutcome.self, from: Data(result.standardOutput.utf8))
    #expect(result.exitCode == 0)
    #expect(outcome.status == .passed)
    #expect(runner.command?.executable == "Tests/Support/embedded-swift-smoke.sh")
    #expect(runner.command?.environment["EMBEDDED_DEVICE"] == "/dev/test")
}

@Test
func optionalHardwareSkipsWhenDeviceLeaseIsContended() throws {
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        deviceLeaseManager: StubDeviceLeaseManager(available: false),
        fileSystem: StubFileSystem(paths: ["/dev/test"]),
        environment: projectEnvironment
    )

    let result = dispatcher.run(arguments: ["hardware", "check", "--device", "/dev/test"])
    let outcome = try JSONDecoder().decode(AxolotyHardwareOutcome.self, from: Data(result.standardOutput.utf8))

    #expect(result.exitCode == 0)
    #expect(outcome.status == .skipped)
    #expect(outcome.reason == "device lease is unavailable")
}

@Test
func hardwareContextMismatchPrecedesFilesystemAndDeviceLeaseEffects() throws {
    let fileSystem = RecordingFileSystem()
    let leases = RecordingDeviceLeaseManager()
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        deviceLeaseManager: leases,
        fileSystem: fileSystem,
        environment: [:]
    )

    let result = dispatcher.run(arguments: ["hardware", "require", "--device", "/dev/test"])

    #expect(result.exitCode == 64)
    #expect(fileSystem.checkedPaths.isEmpty)
    #expect(leases.acquiredDevices.isEmpty)
    #expect(try decodeDiagnostic(result) == AxolotyExecutionContextDiagnostic(
        executable: "Tests/Support/embedded-swift-smoke.sh",
        declaredContext: .project,
        detectedContext: .host
    ))
}

@Test
func checkpointHardwareContextMismatchPrecedesFilesystemEffects() throws {
    let fileSystem = RecordingFileSystem()
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        fileSystem: fileSystem,
        environment: [:]
    )

    let result = dispatcher.run(arguments: ["release", "checkpoint-hardware"])

    #expect(result.exitCode == 64)
    #expect(fileSystem.checkedPaths.isEmpty)
    #expect(try decodeDiagnostic(result) == AxolotyExecutionContextDiagnostic(
        executable: "swift",
        declaredContext: .project,
        detectedContext: .host
    ))
}

@Test
func checkpointContextMismatchPrecedesPlanAndMetadataCommands() throws {
    let runner = RecordingSequenceRunner()
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: runner,
        fileSystem: StubFileSystem(paths: []),
        environment: [:]
    )

    let result = dispatcher.run(arguments: ["release", "checkpoint"])

    #expect(result.exitCode == 64)
    #expect(runner.commands.isEmpty)
    #expect(try decodeDiagnostic(result) == AxolotyExecutionContextDiagnostic(
        executable: "swift",
        declaredContext: .project,
        detectedContext: .host
    ))
}

@Test
func wireVerifyRunsOnlyItsDependencyClosure() throws {
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        fileSystem: StubFileSystem(paths: []),
        environment: projectEnvironment
    )

    let result = dispatcher.run(arguments: ["wire", "verify"])
    let manifest = try JSONDecoder().decode(AxolotyCheckManifest.self, from: Data(result.standardOutput.utf8))

    #expect(result.exitCode == 0)
    #expect(manifest.schemaVersion == 1)
    #expect(manifest.results.map(\.name) == ["resolve", "build", "test-wire"])
}

@Test
func wireVerifyBundleRunsSemanticAndHashVerification() throws {
    let runner = RecordingSequenceRunner()
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: runner,
        fileSystem: StubFileSystem(paths: []),
        environment: projectEnvironment
    )

    let result = dispatcher.run(arguments: ["wire", "verify", ".testing/downloaded"])
    let manifest = try JSONDecoder().decode(AxolotyCheckManifest.self, from: Data(result.standardOutput.utf8))

    #expect(result.exitCode == 0)
    #expect(manifest.results.map(\.name) == ["resolve", "build", "test-wire", "wire-bundle-verify"])
    #expect(runner.commands.last?.arguments == [
        "Tests/Support/release-snapshots.mjs", "verify", ".testing/downloaded",
    ])
}

@Test
func wireCaptureRunsEveryNodeThroughSupportedBridge() throws {
    let bridge = try BridgeCapabilityFixture()
    let runner = RecordingSequenceRunner()
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: runner,
        fileSystem: StubFileSystem(paths: []),
        environment: bridge.environment
    )

    let result = dispatcher.run(arguments: ["wire", "capture"])

    #expect(result.exitCode == 0)
    let manifest = try JSONDecoder().decode(AxolotyCheckManifest.self, from: Data(result.standardOutput.utf8))
    #expect(manifest.results.allSatisfy { $0.status == .passed })
    #expect(runner.commands.count == 10)
    #expect(runner.commands.prefix(2).allSatisfy { $0.executionContext == .project })
    #expect(runner.commands.dropFirst(2).dropLast().allSatisfy { $0.executionContext == .host })
    #expect(runner.commands.last?.executionContext == .project)
}

@Test
func wireCaptureRejectsHostNodesWithoutBridgeBeforeStartingCommands() throws {
    let runner = RecordingSequenceRunner()
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: runner,
        fileSystem: StubFileSystem(paths: []),
        environment: projectEnvironment
    )

    let result = dispatcher.run(arguments: ["wire", "capture"])

    #expect(result.exitCode == 1)
    #expect(runner.commands.isEmpty)
    let manifest = try JSONDecoder().decode(AxolotyCheckManifest.self, from: Data(result.standardOutput.utf8))
    let diagnosticData = try #require(
        manifest.results.first { $0.status == .failed }?.command?.standardError.data(using: .utf8)
    )
    #expect(try JSONDecoder().decode(AxolotyExecutionContextDiagnostic.self, from: diagnosticData) ==
        AxolotyExecutionContextDiagnostic(
            executable: "Tests/WireCompatibility/Live/run-coatyjs-advertise.sh",
            declaredContext: .host,
            detectedContext: .project
        ))
}

@Test
func testOfflineUsesTheCheckPlan() throws {
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        fileSystem: StubFileSystem(paths: []),
        environment: projectEnvironment
    )

    let result = dispatcher.run(arguments: ["test", "offline"])
    let manifest = try JSONDecoder().decode(AxolotyCheckManifest.self, from: Data(result.standardOutput.utf8))

    #expect(result.exitCode == 0)
    #expect(manifest.results.map(\.name) == AxolotyCheckPlan.initialOffline.nodes.map(\.name))
}

@Test
func testToolingUsesOnlyItsCheckPlanDependencyClosure() throws {
    let runner = RecordingSequenceRunner()
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: runner,
        fileSystem: StubFileSystem(paths: []),
        environment: projectEnvironment
    )

    let result = dispatcher.run(arguments: ["test", "tooling"])
    let manifest = try JSONDecoder().decode(AxolotyCheckManifest.self, from: Data(result.standardOutput.utf8))

    #expect(result.exitCode == 0)
    #expect(manifest.results.map(\.name) == ["resolve", "build", "test-tooling"])
    #expect(runner.commands.last?.arguments == [
        "test", "-Xswiftc", "-warnings-as-errors", "--cache-path", ".swiftpm-cache",
        "--disable-automatic-resolution", "--filter",
        "AxolotyCommandDispatcherTests|AxolotyDeviceLeaseTests|AxolotyDevelopmentServiceTests|AxolotyMQTTServiceTests|AxolotyServeParserTests|AxolotyInspectorCoreTests|AxolotyInspectorRuntimeTests|AxolotyMCPTests",
    ])
}

@Test
func integrationTestStartsBrokerBeforeTransportTests() throws {
    let runner = StubIntegrationRunner(result: AxolotyCheckCommandResult(exitCode: 0, standardOutput: "passed"))
    let dispatcher = AxolotyCommandDispatcher(
        integrationRunner: runner,
        fileSystem: StubFileSystem(paths: []),
        environment: projectEnvironment
    )

    let result = dispatcher.run(arguments: ["test", "integration"])
    let manifest = try JSONDecoder().decode(AxolotyCheckManifest.self, from: Data(result.standardOutput.utf8))

    #expect(result.exitCode == 0)
    #expect(manifest.results.map(\.name) == ["integration-tests"])
    #expect(manifest.results.first?.command?.standardOutput == "passed")
}

@Test
func integrationContextMismatchPrecedesIntegrationRunnerEffects() throws {
    let integrationRunner = RecordingIntegrationRunner()
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        integrationRunner: integrationRunner,
        environment: [:]
    )

    let result = dispatcher.run(arguments: ["test", "integration"])

    #expect(result.exitCode == 64)
    #expect(integrationRunner.runCount == 0)
    #expect(try decodeDiagnostic(result) == AxolotyExecutionContextDiagnostic(
        executable: "node",
        declaredContext: .project,
        detectedContext: .host
    ))
}

private struct StubIntegrationRunner: AxolotyIntegrationRunning {
    let result: AxolotyCheckCommandResult
    func run() -> AxolotyCheckCommandResult { result }
}

@Test
func releaseSnapshotsGenerateThenVerifyConfiguredBundle() throws {
    let runner = RecordingSequenceRunner()
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: runner,
        fileSystem: StubFileSystem(paths: []),
        environment: [
            "AXOLOTY_DEVCONTAINER": "1",
            "AXOLOTY_SNAPSHOT_SOURCE": "fixtures",
            "AXOLOTY_SNAPSHOT_OUTPUT": "artifacts",
            "AXOLOTY_IMAGE_IDENTITY": "sha256:test",
            "AXOLOTY_GIT_COMMIT": "abc123",
            "AXOLOTY_GIT_CLEAN": "true",
            "AXOLOTY_CONSUMER_REPOSITORY_URL": "file:///tmp/axoloty.git",
            "AXOLOTY_CONSUMER_VERSION": "9.9.9",
        ]
    )

    let result = dispatcher.run(arguments: ["release", "snapshots"])
    let manifest = try JSONDecoder().decode(AxolotyCheckManifest.self, from: Data(result.standardOutput.utf8))

    #expect(result.exitCode == 0)
    #expect(manifest.results.map(\.name) == ["release-snapshots-generate", "release-snapshots-verify", "release-semver-consumer"])
    #expect(runner.commands.map(\.arguments) == [
        ["Tests/Support/release-snapshots.mjs", "generate", "fixtures", "artifacts"],
        ["Tests/Support/release-snapshots.mjs", "verify", "artifacts"],
        [],
    ])
    #expect(runner.commands.first?.environment["AXOLOTY_IMAGE_IDENTITY"] == "sha256:test")
    #expect(runner.commands.first?.environment["AXOLOTY_GIT_COMMIT"] == "abc123")
    #expect(runner.commands.last?.executable == "Tests/Support/check-axoloty-semver-consumer.sh")
    #expect(runner.commands.last?.environment["AXOLOTY_CONSUMER_VERSION"] == "9.9.9")
}

private final class RecordingSequenceRunner: AxolotyCheckCommandRunning, @unchecked Sendable {
    var commands: [AxolotyCommandPlan] = []
    private(set) var maxConcurrent = 0
    private var currentConcurrent = 0

    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        currentConcurrent += 1
        maxConcurrent = max(maxConcurrent, currentConcurrent)
        commands.append(command)
        currentConcurrent -= 1
        return AxolotyCheckCommandResult(exitCode: 0)
    }
}
