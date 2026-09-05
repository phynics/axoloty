// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

private let projectEnvironment = ["AXOLOTY_DEVCONTAINER": "1"]
struct StubFileSystem: AxolotyFileSystem {
    let paths: Set<String>
    let fileContents: [String: String]

    init(paths: Set<String>, fileContents: [String: String] = [:]) {
        self.paths = paths
        self.fileContents = fileContents
    }

    func exists(atPath path: String) -> Bool { paths.contains(path) }
    func contents(atPath path: String) -> String? { fileContents[path] }
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

private func checkpointManifestFixture() throws -> URL {
    let baseline = try AxolotyCanonicalTestPlanResolver(
        environment: ProcessInfo.processInfo.environment
    ).manifest
    var document = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline)) as? [String: Any]
    )
    let tiers = try #require(document["tiers"] as? [[String: Any]])
    var release = try #require(tiers.first { ($0["id"] as? String) == "release" })
    release["nodes"] = ["resolve"]
    // Only the release category remains, so releaseGates -- derived as every
    // other category -- is empty and the checkpoint runs one command.
    document["tiers"] = [release]
    document["requiredGates"] = []

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-checkpoint-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let override = directory.appending(path: "manifest.json")
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: override)
    return override
}

@Test
func typedInvocationParserClassifiesReleaseCommandsAndEnvironmentFallbacks() {
    let parser = AxolotyCommandParser(environment: ["FILTER": "FallbackSuite", "TIER": "unit"])

    #expect(parser.parse(["release", "checkpoint"]) == .release(.checkpoint(hardware: false)))
    #expect(parser.parse(["release", "checkpoint-hardware"]) == .release(.checkpoint(hardware: true)))
    #expect(parser.parse(["test-one"]) == .testOne(filter: "FallbackSuite"))
    #expect(parser.parse(["test-tier"]) == .testTier(name: "unit", ci: false))
    #expect(parser.parse(["explain"]) == .explain(tier: "unit", ci: false))
}

@Test
func typedInvocationParserPreservesSemanticCommandOwnership() {
    let parser = AxolotyCommandParser(environment: [:])

    #expect(parser.parse(["build"]) == .build)
    #expect(parser.parse(["test", "offline"]) == .testOffline)
    #expect(parser.parse(["test", "tooling"]) == .testTooling)
    #expect(parser.parse(["wire", "verify"]) == .wireVerify)
}

@Test
func helpCommandPrintsUsage() {
    let result = AxolotyCommandDispatcher().run(arguments: ["help"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.contains("Usage: axoloty-tool <command>"))
    #expect(result.standardOutput.contains("test tooling"))
    #expect(result.standardOutput.contains("measure timing"))
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
    #expect(result.standardOutput == "axoloty-tool 0.7.0")
    #expect(result.standardError.isEmpty)
}

@Test
func checkPlanPrintsStableJSON() throws {
    let result = AxolotyCommandDispatcher().run(arguments: ["check", "--plan"])

    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)
    let plan = try? JSONDecoder().decode(AxolotyCheckPlan.self, from: Data(result.standardOutput.utf8))
    // The plan is the ci category. Deriving the expectation from the manifest
    // keeps this honest when a node is added: a literal roster silently
    // encodes one platform's answer and has to be rewritten every time.
    let manifest = try #require(try? AxolotyCanonicalTestPlanResolver(
        environment: ProcessInfo.processInfo.environment
    ).manifest)
    let ci = try #require(manifest.tiers.first { $0.id == "ci" })
    let names = try #require(plan?.nodes.map(\.name))

    #expect(!names.isEmpty)
    #expect(Set(names).count == names.count, "the plan must not repeat a node")
    #expect(Set(names).isSubset(of: Set(ci.nodes)), "the plan must not reach outside the ci category")
    // Ordering is a dependency fact: nothing may run before what it depends on.
    let position = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset) })
    for node in manifest.nodes where position[node.id] != nil {
        for dependency in node.dependencies {
            if let earlier = position[dependency] {
                #expect(earlier < position[node.id]!, "\(dependency) must precede \(node.id)")
            }
        }
    }
    // A category declaring no hardware must never resolve a hardware node.
    for name in names {
        #expect(manifest.nodes.first { $0.id == name }?.hardware == AxolotyTestHardwarePolicy.forbidden)
    }
    for expected in ["resolve", "build", "lint", "test-tooling", "test-unit", "test-module", "test-wire"] {
        #expect(names.contains(expected), "\(expected) must be part of the ci category")
    }
    #expect(plan?.nodes.first(where: { $0.name == "lint" })?.command.arguments == [
        "lint", "--no-cache", "--config", ".swiftlint.yml",
    ])
    #expect(plan?.nodes.first(where: { $0.name == "test-tooling" })?.command.arguments == [
        "test", "-Xswiftc", "-warnings-as-errors", "--cache-path", ".swiftpm-cache",
        "--disable-automatic-resolution", "--filter",
        "AxolotyCommandDispatcherTests|AxolotyTimingTests|AxolotyDeviceLeaseTests|AxolotyResourceLeaseTests|AxolotyDevelopmentServiceTests|AxolotyMQTTServiceTests|AxolotyServeParserTests|RepositoryAuthorityTests|AxolotyInspectorCoreTests|AxolotyInspectorRuntimeTests|AxolotyMCPTests",
    ])
    #expect(plan?.nodes.allSatisfy { timeout in
        guard let seconds = timeout.command.timeoutSeconds else { return false }
        return seconds.isFinite && seconds > 0
    } == true)
}

@Test
func ciCategorySelectsTheFullObjectModelAggregate() throws {
    let runner = RecordingSequenceRunner()
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: runner,
        fileSystem: StubFileSystem(paths: []),
        environment: projectEnvironment
    )

    let result = dispatcher.run(arguments: ["test-tier", CanonicalTier.ci.rawValue])
    let manifest = try JSONDecoder().decode(
        AxolotyCheckManifest.self,
        from: Data(result.standardOutput.utf8)
    )
    let names = manifest.results.map(\.name)

    #expect(result.exitCode == 0)
    #expect(names.contains("g3-object-boundary"))
    #expect(names.contains("g3-object-model-package"))
    #expect(names.contains("g3-object-model-tests"))
    #expect(names.contains("g3-object-macros-tests"))
    #expect(names.contains("g3-coaty-models-tests"))
    #expect(names.contains("g3-object-model-evidence-host"))
    #expect(names.contains("g3-object-model-evidence-sanitized"))
    #if os(Linux)
    #expect(names.contains("g3-object-model-evidence-embedded"))
    #else
    #expect(!names.contains("g3-object-model-evidence-embedded"))
    #endif
}

@Test
func canonicalManifestDefinesVerifyRootsAndBoundedTestOne() throws {
    let resolver = try AxolotyCanonicalTestPlanResolver(environment: ProcessInfo.processInfo.environment)
    let manifest = resolver.manifest
    #expect(manifest.schemaVersion == 2)
    #expect(manifest.requiredGates.allSatisfy { gate in manifest.nodes.contains { $0.id == gate } })
    // requiredGates is the ci category, and releaseGates is derived from the
    // declared categories rather than stored beside them.
    #expect(Set(manifest.requiredGates).isSubset(of: Set(manifest.tiers.first { $0.id == "ci" }?.nodes ?? [])))
    #expect(manifest.releaseGates == ["ci", "wire", "embedded"])
    #expect(manifest.toolContainerEnv?.allowlist(for: "release-checkpoint")?.contains("AXOLOTY_GIT_TREE") == true)
    #expect(manifest.toolContainerEnv?.allowlist(for: "release-checkpoint-hardware")?.contains("AXOLOTY_DEVICE") == true)
    #expect(manifest.toolContainerEnv?.allowlist(for: "release-unknown") == nil)
    #expect(try resolver.command(.testOne(filter: "suite;touch /tmp/injected")).arguments.last == "suite;touch /tmp/injected")
    #expect(manifest.testOne.timeoutSeconds > 0)
    #expect(try resolver.resolve(.tier(
        name: CanonicalTier.wire.rawValue,
        ci: false,
        platform: AxolotyCheckPlan.currentPlatform
    )).deadlineSeconds == 3_600)
    #expect(try resolver.resolve(.tier(name: CanonicalTier.ci.rawValue, ci: true,
        platform: AxolotyCheckPlan.currentPlatform,
        requested: nil
    )).deadlineSeconds == 3_600)
}

@Test
func canonicalSwiftBuildsTreatWarningsAsErrors() throws {
    let manifest = try AxolotyCanonicalTestPlanResolver(
        environment: ProcessInfo.processInfo.environment
    ).manifest
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
    let data = try JSONEncoder().encode(AxolotyCanonicalTestPlanResolver(
        environment: ProcessInfo.processInfo.environment
    ).manifest)
    var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    document["manifestID"] = "axoloty-test-override"
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-manifest-\(UUID().uuidString)", directoryHint: .isDirectory)
    let override = directory.appending(path: "manifest.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: override)

    let resolver = try AxolotyCanonicalTestPlanResolver(environment: [
        "AXOLOTY_TEST_MANIFEST": override.path,
    ])

    #expect(resolver.manifest.manifestID == "axoloty-test-override")
}

@Test
func checkpointPlanningAndCertificationUseOneManifestSnapshot() throws {
    let baseline = try AxolotyCanonicalTestPlanResolver(
        environment: ProcessInfo.processInfo.environment
    ).manifest
    var document = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline)) as? [String: Any]
    )
    // releaseGates is every category except release, so a fixture names its
    // gate by declaring exactly one other category.
    let tiers = try #require(document["tiers"] as? [[String: Any]])
    var release = try #require(tiers.first { ($0["id"] as? String) == "release" })
    var gate = try #require(tiers.first { ($0["id"] as? String) == "ci" })
    release["nodes"] = ["resolve"]
    gate["nodes"] = ["resolve"]
    gate["id"] = "smoke"
    document["tiers"] = [gate, release]
    document["requiredGates"] = []
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-manifest-snapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
    let override = directory.appending(path: "manifest.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: override)

    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        fileSystem: StubFileSystem(paths: []),
        environment: projectEnvironment.merging([
            "AXOLOTY_TEST_MANIFEST": override.path,
        ]) { _, value in value }
    )

    // Rewrite the file after the dispatcher was constructed: a different gate
    // and nothing to run. The assertions below prove the first snapshot was
    // the one used for both planning and certification.
    gate["id"] = "unit"
    release["nodes"] = []
    document["tiers"] = [gate, release]
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: override)

    let result = dispatcher.run(arguments: ["release", "checkpoint"])
    let certificate = try JSONDecoder().decode(
        AxolotyCheckpointManifest.self,
        from: Data(result.standardOutput.utf8)
    )

    #expect(!certificate.results.isEmpty)
    #expect(certificate.releaseGates.map(\.id) == ["smoke"])
}

@Test
func verifyPlanIncludesStaticSupportWithoutRecursiveGates() throws {
    let resolver = try AxolotyCanonicalTestPlanResolver(environment: ProcessInfo.processInfo.environment)
    let ordinary = try resolver.resolve(.tier(name: CanonicalTier.ci.rawValue, ci: false,
        platform: AxolotyCheckPlan.currentPlatform,
        requested: nil
    ))
    #expect(ordinary.nodes.contains { $0.name == "support-tier-contract" })
    #expect(ordinary.nodes.contains { $0.name == "no-anycodable" })
    #expect(!ordinary.nodes.contains { $0.name == "integration-tests" })
    #expect(!ordinary.nodes.contains { $0.name == "logging-global" })
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
    let result = dispatcher.run(arguments: ["explain", CanonicalTier.ci.rawValue])
    #expect(result.exitCode == 0)
    #expect(result.standardOutput.contains("PLAN ci"))
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
    #expect(runner.command?.executable == "Tests/Support/checks/check-embedded-environment.sh")
}

@Test
func checkPlanDisablesSwiftLintCache() throws {
    let resolver = try AxolotyCanonicalTestPlanResolver(environment: ProcessInfo.processInfo.environment)
    let plan = try resolver.resolve(.tier(name: CanonicalTier.ci.rawValue, ci: false, platform: .linux, requested: nil))
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
    #expect(runner.command?.executable == "Tests/Support/embedded/embedded-swift-test.sh")
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
        executable: "Tests/Support/embedded/embedded-swift-test.sh",
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
func checkpointPlanIncludesRequiredCompatibilityNodes() throws {
    let resolver = try AxolotyCanonicalTestPlanResolver(environment: ProcessInfo.processInfo.environment)
    let plan = try resolver.resolve(.checkpoint(
        hardwareDevice: nil,
        consumerEnvironment: [:],
        platform: AxolotyCheckPlan.currentPlatform
    ))

    #expect(!plan.nodes.contains { $0.name == "integration-tests" })
    #expect(!plan.nodes.contains { $0.name == "logging-global" })
    #expect(plan.nodes.contains { $0.name == "g3-object-model-evidence-host" })
    #expect(plan.nodes.contains { $0.name == "g3-object-model-evidence-sanitized" })
    #expect(plan.nodes.contains { $0.name == "g3-object-model-evidence-embedded" })

    let hardwarePlan = try resolver.resolve(.checkpoint(
        hardwareDevice: "/dev/ttyACM0",
        consumerEnvironment: [:],
        platform: AxolotyCheckPlan.currentPlatform
    ))
    #expect(!hardwarePlan.nodes.contains { $0.name == "integration-tests" })
    #expect(!hardwarePlan.nodes.contains { $0.name == "logging-global" })
    #expect(hardwarePlan.nodes.contains { $0.name == "g3-object-model-evidence-host" })
    #expect(hardwarePlan.nodes.contains { $0.name == "g3-object-model-evidence-sanitized" })
    #expect(hardwarePlan.nodes.contains { $0.name == "g3-object-model-evidence-embedded" })
}

@Test
func checkpointFailsWhenRequiredReleaseGateHasNoEvidence() throws {
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        integrationRunner: StubIntegrationRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        fileSystem: StubFileSystem(paths: []),
        environment: projectEnvironment
    )

    let result = dispatcher.run(arguments: ["release", "checkpoint"])
    let manifest = try JSONDecoder().decode(AxolotyCheckpointManifest.self, from: Data(result.standardOutput.utf8))

    #expect(result.exitCode == 1)
    let wireLive = try #require(manifest.releaseGates.first { $0.id == "wire" })
    #expect(wireLive.result == .skipped)
    #expect(manifest.releaseGates.contains { $0.result == .skipped })
}

@Test
func checkpointFailsWhenReleaseCheckoutIsDirty() throws {
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: DirtyCheckoutRunner(),
        fileSystem: StubFileSystem(paths: []),
        environment: projectEnvironment
    )

    let result = dispatcher.run(arguments: ["release", "checkpoint"])
    let manifest = try JSONDecoder().decode(
        AxolotyCheckpointManifest.self,
        from: Data(result.standardOutput.utf8)
    )

    #expect(result.exitCode == 1)
    #expect(!manifest.gitClean)
}

@Test
func checkpointRejectsLegacyGenericExternallyAttestedReleaseGate() throws {
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        integrationRunner: StubIntegrationRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        fileSystem: StubFileSystem(
            paths: [".testing/wire/manifest.json"],
            fileContents: [
                ".testing/wire/manifest.json": "{\"schemaVersion\":1,\"status\":\"passed\"}",
            ]
        ),
        environment: projectEnvironment.merging([
            "AXOLOTY_ATTESTATION_WIRE_PATH": ".testing/wire/manifest.json",
        ]) { _, value in value }
    )

    let result = dispatcher.run(arguments: ["release", "checkpoint"])
    let manifest = try JSONDecoder().decode(AxolotyCheckpointManifest.self, from: Data(result.standardOutput.utf8))

    #expect(result.exitCode == 1)
    let wireLive = try #require(manifest.releaseGates.first { $0.id == "wire" })
    #expect(wireLive.result == .failed)
    #expect(wireLive.evidence == ".testing/wire/manifest.json")
}

@Test
func checkpointRejectsInvalidExternallyAttestedReleaseGate() throws {
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        integrationRunner: StubIntegrationRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        fileSystem: StubFileSystem(
            paths: [".testing/wire/manifest.json"],
            fileContents: [
                ".testing/wire/manifest.json": "{\"schemaVersion\":1,\"status\":\"failed\"}",
            ]
        ),
        environment: projectEnvironment.merging([
            "AXOLOTY_ATTESTATION_WIRE_PATH": ".testing/wire/manifest.json",
        ]) { _, value in value }
    )

    let result = dispatcher.run(arguments: ["release", "checkpoint"])
    let manifest = try JSONDecoder().decode(AxolotyCheckpointManifest.self, from: Data(result.standardOutput.utf8))

    #expect(result.exitCode == 1)
    let wireLive = try #require(manifest.releaseGates.first { $0.id == "wire" })
    #expect(wireLive.result == .failed)
}

@Test
func checkpointManifestRecordsAllRequiredReleaseGatesInOrder() throws {
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        integrationRunner: StubIntegrationRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        environment: projectEnvironment.merging([
            "AXOLOTY_ATTESTATION_WIRE_PATH": ".testing/wire/manifest.json",
        ]) { _, value in value }
    )

    let result = dispatcher.run(arguments: ["release", "checkpoint"])
    let manifest = try JSONDecoder().decode(AxolotyCheckpointManifest.self, from: Data(result.standardOutput.utf8))

    #expect(manifest.schemaVersion == 3)
    #expect(manifest.releaseGates.map(\.id) == ["ci", "wire", "embedded"])
    #expect(manifest.releaseGates.first { $0.id == "integration" } == nil)
}

@Test
func releaseCheckpointUsesTheInjectedExecutorEventSink() {
    let manifestURL = try! checkpointManifestFixture()
    defer { try? FileManager.default.removeItem(at: manifestURL.deletingLastPathComponent()) }
    let events = RecordingEventSink()
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        fileSystem: StubFileSystem(paths: []),
        environment: projectEnvironment.merging([
            "AXOLOTY_TEST_MANIFEST": manifestURL.path,
        ]) { _, value in value },
        eventSink: { event in events.append(event.diagnosticLine()) },
        clock: CheckTestClock(),
        overrunScheduler: ManualOverrunScheduler()
    )

    let result = dispatcher.run(arguments: ["release", "checkpoint"])

    #expect(result.standardError.isEmpty)
    // The release category declares an expected duration; the plan it replaced
    // declared none.
    #expect(events.lines == [
        "[axoloty] event=plan-start expected=9000.000s\n",
        "[axoloty] event=node-start node=resolve expected=60.000s lease-wait=0.000s\n",
        "[axoloty] event=node-completion node=resolve status=passed elapsed=0.000s expected=60.000s lease-wait=0.000s\n",
        "[axoloty] event=plan-completion status=passed elapsed=0.000s expected=9000.000s lease-wait=0.000s output-bytes=0\n",
    ])
}

@Test
func releaseCheckpointHumanOutputIsExactlyTheCheckSummary() throws {
    let override = try checkpointManifestFixture()
    defer { try? FileManager.default.removeItem(at: override.deletingLastPathComponent()) }
    let environment = projectEnvironment.merging([
        "AXOLOTY_OUTPUT": "human",
        "AXOLOTY_TEST_MANIFEST": override.path,
    ]) { _, value in value }
    let result = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        fileSystem: StubFileSystem(paths: []),
        environment: environment,
        timestampProvider: { "2026-09-01T00:00:00Z" },
        clock: CheckTestClock(),
        overrunScheduler: ManualOverrunScheduler()
    ).run(arguments: ["release", "checkpoint"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "PASSED resolve\n")
    #expect(result.standardError.isEmpty)
}

@Test
func releaseCheckpointRendersCompleteDeterministicJSONBytes() throws {
    let override = try checkpointManifestFixture()
    defer { try? FileManager.default.removeItem(at: override.deletingLastPathComponent()) }
    let environment = projectEnvironment.merging([
        "AXOLOTY_TEST_MANIFEST": override.path,
        "AXOLOTY_GIT_COMMIT": String(repeating: "a", count: 40),
        "AXOLOTY_GIT_TREE": String(repeating: "b", count: 40),
        "AXOLOTY_REPOSITORY": "github.com/phynics/axoloty",
    ]) { _, value in value }
    let result = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        fileSystem: StubFileSystem(
            paths: [],
            fileContents: [:]
        ),
        environment: environment,
        timestampProvider: { "2026-09-01T00:00:00Z" },
        clock: CheckTestClock(),
        overrunScheduler: ManualOverrunScheduler()
    ).run(arguments: ["release", "checkpoint"])
    #if os(Linux)
    let platform = "linux"
    #else
    let platform = "macOS"
    #endif
    let expectedLines = [
        "{",
        "  \"gitBranch\" : \"\",",
        "  \"gitClean\" : true,",
        "  \"gitCommit\" : \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",",
        "  \"gitTree\" : \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",",
        "  \"hardwareIncluded\" : false,",
        "  \"platform\" : \"\(platform)\",",
        "  \"releaseGates\" : [",
        "",
        "  ],",
        "  \"releaseVersion\" : \"unavailable\",",
        "  \"repository\" : \"github.com\\/phynics\\/axoloty\",",
        "  \"results\" : [",
        "    {",
        "      \"command\" : {",
        "        \"exitCode\" : 0,",
        "        \"standardError\" : \"\",",
        "        \"standardOutput\" : \"\"",
        "      },",
        "      \"name\" : \"resolve\",",
        "      \"status\" : \"passed\",",
        "      \"timing\" : {",
        "        \"elapsedSeconds\" : 0,",
        "        \"exceededExpectation\" : false,",
        "        \"expectedDurationSeconds\" : 60,",
        "        \"resourceLeaseWaitSeconds\" : 0",
        "      }",
        "    }",
        "  ],",
        "  \"schemaVersion\" : 3,",
        "  \"swiftVersion\" : \"\",",
        "  \"timestamp\" : \"2026-09-01T00:00:00Z\"",
        "}"
    ]
    let expectedBytes = Data(expectedLines.joined(separator: "\n").utf8)

    #expect(result.exitCode == 0)
    #expect(Data(result.standardOutput.utf8) == expectedBytes)
    #expect(result.standardError.isEmpty)
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
func wireCaptureRunsEveryNodeThroughSupportedBridge() throws {
    let clock = ContinuousClock()
    let startedAt = clock.now
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
    #expect(runner.commands.count == 13)
    #expect(runner.commands.prefix(2).allSatisfy { $0.executionContext == .project })
    #expect(runner.commands.dropFirst(2).dropLast().allSatisfy { $0.executionContext == .host })
    #expect(runner.commands.last?.executionContext == .project)
    #expect(clock.now - startedAt < .seconds(5))
}

/// The wire category resolved as a plain tier must point the manifest node at
/// `WIRE_OUTPUT_DIR`, exactly as `wire capture` does. CI runs `test-tier wire`
/// with that variable overridden, so a tier plan that kept the literal
/// `.testing/wire` token indexed a directory no capture wrote.
@Test
func wireTierPointsTheManifestNodeAtTheConfiguredOutputDirectory() throws {
    let outputDirectory = ".testing/runs/tier-wire/wire"
    let resolver = try AxolotyCanonicalTestPlanResolver(
        environment: ProcessInfo.processInfo.environment.merging([
            "WIRE_OUTPUT_DIR": outputDirectory,
        ]) { _, value in value }
    )

    let plan = try resolver.resolve(.tier(
        name: CanonicalTier.wire.rawValue,
        ci: false,
        platform: .linux
    ))
    let manifestNode = try #require(plan.nodes.first { $0.name == "wire-capture-manifest" })

    #expect(manifestNode.command.arguments == [
        "Tests/Support/WireCompatibility/tool/dist/index.js",
        "manifest",
        outputDirectory,
        "\(outputDirectory)/manifest.json",
    ])
    #expect(manifestNode.command.environment["WIRE_OUTPUT_DIR"] == outputDirectory)
}

/// Without an override the token stays literal, so ordinary local runs keep
/// writing and indexing `.testing/wire`.
@Test
func wireTierKeepsTheDefaultOutputDirectoryWhenUnset() throws {
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "WIRE_OUTPUT_DIR")
    let resolver = try AxolotyCanonicalTestPlanResolver(environment: environment)

    let plan = try resolver.resolve(.tier(
        name: CanonicalTier.wire.rawValue,
        ci: false,
        platform: .linux
    ))
    let manifestNode = try #require(plan.nodes.first { $0.name == "wire-capture-manifest" })

    #expect(manifestNode.command.arguments.dropFirst(2) == [
        ".testing/wire",
        ".testing/wire/manifest.json",
    ])
}

@Test
func wireCaptureForwardsInvocationScopedOutputToEveryNode() throws {
    let bridge = try BridgeCapabilityFixture()
    let runner = RecordingSequenceRunner()
    let outputDirectory = ".testing/runs/concurrent-wire/wire"
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: runner,
        fileSystem: StubFileSystem(paths: []),
        environment: bridge.environment.merging([
            "AXOLOTY_RUN_ID": "concurrent-wire",
            "WIRE_OUTPUT_DIR": outputDirectory,
        ]) { _, value in value }
    )

    let result = dispatcher.run(arguments: ["wire", "capture"])

    #expect(result.exitCode == 0)
    #expect(runner.commands.allSatisfy { $0.environment["WIRE_OUTPUT_DIR"] == outputDirectory })
    #expect(runner.commands.allSatisfy { $0.environment["WIRE_RUN_ID"] == "concurrent-wire" })
    #expect(runner.commands.last?.arguments == [
        "Tests/Support/WireCompatibility/tool/dist/index.js",
        "manifest",
        outputDirectory,
        "\(outputDirectory)/manifest.json",
    ])
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
            executable: "Tests/Support/WireCompatibility/Live/prepare-live-suite.sh",
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
    let resolver = try AxolotyCanonicalTestPlanResolver(environment: projectEnvironment)
    let plan = try resolver.resolve(.tier(name: CanonicalTier.ci.rawValue, ci: false,
        platform: AxolotyCheckPlan.currentPlatform,
        requested: nil
    ))
    #expect(manifest.results.map(\.name) == plan.nodes.map(\.name))
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
        "AxolotyCommandDispatcherTests|AxolotyTimingTests|AxolotyDeviceLeaseTests|AxolotyResourceLeaseTests|AxolotyDevelopmentServiceTests|AxolotyMQTTServiceTests|AxolotyServeParserTests|RepositoryAuthorityTests|AxolotyInspectorCoreTests|AxolotyInspectorRuntimeTests|AxolotyMCPTests",
    ])
}

@Test
func integrationCommandReportsRetirementWithoutRunningAProcess() {
    let runner = StubIntegrationRunner(result: AxolotyCheckCommandResult(exitCode: 0, standardOutput: "passed"))
    let dispatcher = AxolotyCommandDispatcher(
        integrationRunner: runner,
        fileSystem: StubFileSystem(paths: []),
        environment: projectEnvironment
    )

    let result = dispatcher.run(arguments: ["test", "integration"])

    #expect(result.exitCode == 69)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.contains("broker-backed integration tier is retired"))
}

@Test
func retiredIntegrationCommandDoesNotRunTheInjectedRunner() {
    let integrationRunner = RecordingIntegrationRunner()
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: StubRunner(result: AxolotyCheckCommandResult(exitCode: 0)),
        integrationRunner: integrationRunner,
        environment: [:]
    )

    let result = dispatcher.run(arguments: ["test", "integration"])

    #expect(result.exitCode == 69)
    #expect(integrationRunner.runCount == 0)
    #expect(result.standardError.contains("broker-backed integration tier is retired"))
}

private struct StubIntegrationRunner: AxolotyIntegrationRunning {
    let result: AxolotyCheckCommandResult
    func run() -> AxolotyCheckCommandResult { result }
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

private final class RecordingEventSink: @unchecked Sendable {
    private(set) var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
    }
}

private struct DirtyCheckoutRunner: AxolotyCheckCommandRunning {
    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        if command.arguments == ["status", "--porcelain"] {
            return AxolotyCheckCommandResult(exitCode: 0, standardOutput: " M VERSION\n")
        }
        if command.arguments == ["rev-parse", "HEAD"] {
            return AxolotyCheckCommandResult(
                exitCode: 0,
                standardOutput: "0123456789012345678901234567890123456789\n"
            )
        }
        return AxolotyCheckCommandResult(exitCode: 0)
    }
}
