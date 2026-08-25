// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private func node(_ name: String, dependencies: [String] = []) -> AxolotyCheckNode {
    AxolotyCheckNode(name: name, dependencies: dependencies, command: AxolotyCommandPlan(executable: name))
}

private struct StubCommandRunner: AxolotyCheckCommandRunning {
    let failedCommands: Set<String>

    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        AxolotyCheckCommandResult(
            exitCode: failedCommands.contains(command.executable) ? 1 : 0,
            standardOutput: command.executable
        )
    }
}

private final class CheckTestClock: AxolotyTimingClock, @unchecked Sendable {
    private(set) var value: TimeInterval

    init(_ value: TimeInterval = 0) {
        self.value = value
    }

    func now() -> TimeInterval {
        value
    }

    func advance(by seconds: TimeInterval) {
        value += seconds
    }
}

private final class DeadlineRecordingRunner: AxolotyCheckCommandRunning, @unchecked Sendable {
    let clock: CheckTestClock
    let failedCommands: Set<String>
    let advancePerCommand: TimeInterval
    private(set) var commands: [AxolotyCommandPlan] = []

    init(
        clock: CheckTestClock,
        failedCommands: Set<String> = [],
        advancePerCommand: TimeInterval = 0
    ) {
        self.clock = clock
        self.failedCommands = failedCommands
        self.advancePerCommand = advancePerCommand
    }

    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        commands.append(command)
        clock.advance(by: advancePerCommand)
        return AxolotyCheckCommandResult(
            exitCode: failedCommands.contains(command.executable) ? 1 : 0
        )
    }
}

private final class OutputEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(AxolotyCommandOutputStream, String)] = []

    func append(_ stream: AxolotyCommandOutputStream, _ text: String) {
        lock.lock()
        events.append((stream, text))
        lock.unlock()
    }

    func text(for stream: AxolotyCommandOutputStream) -> String {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0.0 == stream }.map(\.1).joined()
    }
}

private final class CommandResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AxolotyCheckCommandResult?

    func store(_ result: AxolotyCheckCommandResult) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    var result: AxolotyCheckCommandResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private func signalIsIgnored(
    _ signalNumber: Int32,
    restoring disposition: (@convention(c) (Int32) -> Void)?
) -> Bool {
    let previous = signal(signalNumber, SIG_DFL)
    let ignored = unsafeBitCast(SIG_IGN, to: UInt.self)
    let current = unsafeBitCast(previous, to: UInt.self)
    if let disposition {
        _ = signal(signalNumber, disposition)
    }
    return current == ignored
}

@Test
func checkpointPlansResolveReleaseSnapshotPlaceholders() throws {
    let source = "Tests/Fixtures/custom"
    let destination = ".testing/custom-release"
    let plans = [
        AxolotyCheckPlan.checkpoint(
            source: source,
            destination: destination,
            consumerEnvironment: [:]
        ),
        AxolotyCheckPlan.checkpointHardware(
            source: source,
            destination: destination
        ),
    ]

    for plan in plans {
        let generate = try #require(plan.nodes.first { $0.name.hasSuffix("fixture-bundle-generate") })
        let verify = try #require(plan.nodes.first { $0.name.hasSuffix("fixture-bundle-verify") })
        #expect(generate.command.arguments == [
            "Tests/Support/fixture-bundle.mjs", "generate", source, destination,
        ])
        #expect(verify.command.arguments == [
            "Tests/Support/fixture-bundle.mjs", "verify", destination,
        ])
        #expect(!generate.command.arguments.contains("${SOURCE}"))
        #expect(!generate.command.arguments.contains("${DESTINATION}"))
    }
}

private func processIsAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

private func waitForFile(_ url: URL, timeout: TimeInterval = 2) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return FileManager.default.fileExists(atPath: url.path)
}

@Test
func signalMultiplexerRestoresPreviousSignalDispositionsAndFansOutConcurrentLeases() {
    let previousInt = signal(SIGINT, SIG_IGN)
    let previousTerm = signal(SIGTERM, SIG_IGN)
    defer {
        _ = signal(SIGINT, previousInt)
        _ = signal(SIGTERM, previousTerm)
    }

    let multiplexer = AxolotySignalMultiplexer()
    let callbackCount = LockedCounter()
    let callbacksReceived = DispatchSemaphore(value: 0)
    let leases = (0..<8).map { _ in
        multiplexer.acquire {
            callbackCount.increment()
            callbacksReceived.signal()
        }
    }
    DispatchQueue.concurrentPerform(iterations: 4) { _ in
        multiplexer.notifyForTesting()
    }
    DispatchQueue.concurrentPerform(iterations: leases.count) { index in
        leases[index].cancel()
    }

    for _ in 0..<(leases.count * 4) {
        _ = callbacksReceived.wait(timeout: .now() + .seconds(2))
    }
    #expect(callbackCount.value == leases.count * 4)
    #expect(signalIsIgnored(SIGINT, restoring: previousInt))
    #expect(signalIsIgnored(SIGTERM, restoring: previousTerm))
}

@Test
func plannerOrdersDependenciesBeforeDependants() throws {
    let plan = try AxolotyCheckPlanner().plan([node("app", dependencies: ["core"]), node("core")])
    #expect(plan.nodes.map(\.name) == ["core", "app"])
}

@Test
func plannerCoalescesDuplicatePrerequisites() throws {
    let plan = try AxolotyCheckPlanner().plan([
        node("root", dependencies: ["left", "right"]),
        node("left", dependencies: ["shared"]),
        node("right", dependencies: ["shared"]),
        node("shared"),
    ])
    #expect(plan.nodes.map(\.name) == ["shared", "left", "right", "root"])
}

@Test
func plannerReportsMissingDependency() {
    do {
        _ = try AxolotyCheckPlanner().plan([node("root", dependencies: ["missing"])])
        Issue.record("Expected missing dependency")
    } catch let error as AxolotyCheckPlanningError {
        #expect(error == .missingDependency(node: "root", dependency: "missing"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func plannerReportsCycles() {
    do {
        _ = try AxolotyCheckPlanner().plan([node("a", dependencies: ["b"]), node("b", dependencies: ["a"])])
        Issue.record("Expected cycle")
    } catch let error as AxolotyCheckPlanningError {
        #expect(error == .cycle(["a", "b", "a"]))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func modelsEncodeAndDecode() throws {
    let plan = try AxolotyCheckPlanner().plan(AxolotyCheckPlan.initialOffline.nodes)
    let data = try JSONEncoder().encode(plan)
    #expect(try JSONDecoder().decode(AxolotyCheckPlan.self, from: data) == plan)
}

@Test
func legacySchemaV1PlanDefaultsMissingExecutionContextAndReencodesItExplicitly() throws {
    let fixture = try #require(Bundle.module.url(
        forResource: "legacy-check-plan-v1",
        withExtension: "json"
    ))
    let plan = try JSONDecoder().decode(
        AxolotyCheckPlan.self,
        from: Data(contentsOf: fixture)
    )

    #expect(plan.schemaVersion == 1)
    #expect(plan.nodes.first?.command.executionContext == .project)

    let encoded = try JSONEncoder().encode(plan)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let nodes = try #require(object["nodes"] as? [[String: Any]])
    let command = try #require(nodes.first?["command"] as? [String: Any])
    #expect(command["executionContext"] as? String == "project")
}

@Test
func offlinePlanOmitsEmbeddedChecksOnMacOS() {
    let plan = AxolotyCheckPlan.initialOffline(for: .macOS)
    #expect(!plan.nodes.contains { $0.name.hasPrefix("embedded-") })
    #expect(!plan.nodes.contains { ["support-container", "support-fuzz-runner"].contains($0.name) })
}

@Test
func offlinePlanIncludesEmbeddedChecksOnLinux() {
    let plan = AxolotyCheckPlan.initialOffline(for: .linux)
    let names = plan.nodes.map(\.name)
    let embeddedBuild = names.firstIndex(of: "embedded-build")
    let embeddedLinker = names.firstIndex(of: "embedded-linker")
    let boundedHost = names.firstIndex(of: "g1-bounded-runtime-host")
    let boundedSanitized = names.firstIndex(of: "g1-bounded-runtime-sanitized")
    let boundedEmbedded = names.firstIndex(of: "g1-bounded-runtime-embedded")
    let objectBoundary = names.firstIndex(of: "g3-object-boundary")
    let objectPackage = names.firstIndex(of: "g3-object-model-package")
    let objectTests = names.firstIndex(of: "g3-object-model-tests")
    let objectMacros = names.firstIndex(of: "g3-object-macros-tests")
    let coatyModels = names.firstIndex(of: "g3-coaty-models-tests")
    let objectHost = names.firstIndex(of: "g3-object-model-evidence-host")
    let objectSanitized = names.firstIndex(of: "g3-object-model-evidence-sanitized")
    let objectEmbedded = names.firstIndex(of: "g3-object-model-evidence-embedded")

    #expect(embeddedBuild != nil)
    #expect(embeddedLinker != nil)
    #expect(boundedHost != nil)
    #expect(boundedSanitized != nil)
    #expect(boundedEmbedded != nil)
    #expect(objectBoundary != nil)
    #expect(objectPackage != nil)
    #expect(objectTests != nil)
    #expect(objectMacros != nil)
    #expect(coatyModels != nil)
    #expect(objectHost != nil)
    #expect(objectSanitized != nil)
    #expect(objectEmbedded != nil)
    if let embeddedBuild, let embeddedLinker, let boundedHost, let boundedSanitized, let boundedEmbedded,
       let objectBoundary, let objectPackage, let objectTests, let objectMacros, let coatyModels,
       let objectHost, let objectSanitized, let objectEmbedded {
        #expect(embeddedBuild < embeddedLinker)
        #expect(embeddedLinker < boundedHost)
        #expect(boundedHost < boundedSanitized)
        #expect(boundedSanitized < boundedEmbedded)
        #expect(boundedEmbedded < objectBoundary)
        #expect(objectBoundary < objectPackage)
        #expect(objectPackage < objectTests)
        #expect(objectTests < objectMacros)
        #expect(objectMacros < coatyModels)
        #expect(coatyModels < objectHost)
        #expect(objectHost < objectSanitized)
        #expect(objectSanitized < objectEmbedded)
    }
}

@Test
func executorRunsIndependentNodesAfterFailure() throws {
    let plan = try AxolotyCheckPlanner().plan([
        node("blocked", dependencies: ["failed"]),
        node("independent"),
        node("failed"),
    ])

    let results = AxolotyCheckExecutor(commandRunner: StubCommandRunner(failedCommands: ["failed"])).execute(plan)

    #expect(results.map(\.name) == ["failed", "blocked", "independent"])
    #expect(results.map(\.status) == [.failed, .skipped, .passed])
    #expect(results[1].command == nil)
}

@Test
func executorPassesRemainingPlanBudgetAndContinuesIndependentNodesAfterFailure() throws {
    let clock = CheckTestClock()
    let runner = DeadlineRecordingRunner(
        clock: clock,
        failedCommands: ["failed"],
        advancePerCommand: 3
    )
    let plan = try AxolotyCheckPlanner().plan(
        [
            node("blocked", dependencies: ["failed"]),
            node("independent"),
            AxolotyCheckNode(
                name: "failed",
                command: AxolotyCommandPlan(executable: "failed", timeoutSeconds: 2)
            ),
        ],
        deadlineSeconds: 10
    )
    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )

    let results = AxolotyCheckExecutor(
        commandRunner: runner,
        contextValidator: validator,
        clock: clock
    ).execute(plan)

    #expect(results.map(\.status) == [.failed, .skipped, .passed])
    #expect(runner.commands.map(\.executable) == ["failed", "independent"])
    #expect(runner.commands.map(\.timeoutSeconds) == [2, 7])
}

@Test
func executorMarksAllPendingNodesExpiredWhenACommandExceedsPlanDeadline() throws {
    let clock = CheckTestClock()
    let runner = DeadlineRecordingRunner(clock: clock, advancePerCommand: 6)
    let plan = try AxolotyCheckPlanner().plan(
        [
            node("dependent", dependencies: ["first"]),
            node("independent"),
            node("first"),
        ],
        deadlineSeconds: 5
    )
    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )

    let results = AxolotyCheckExecutor(
        commandRunner: runner,
        contextValidator: validator,
        clock: clock
    ).execute(plan)

    #expect(results.map(\.status) == [.failed, .expired, .expired])
    #expect(runner.commands.map(\.executable) == ["first"])
    #expect(results[0].command?.exitCode == 124)
    #expect(results[0].command?.standardError ==
        "check plan deadline exceeded after node completed: node=first elapsed=6.000s budget=5.000s\n")
    #expect(results[1].command?.standardError ==
        "check plan deadline exceeded before node started: node=dependent elapsed=6.000s budget=5.000s dependencies=first\n")
}

@Test
func executorCapturesCommandResult() throws {
    let plan = try AxolotyCheckPlanner().plan([node("success")])

    let results = AxolotyCheckExecutor(commandRunner: StubCommandRunner(failedCommands: [])).execute(plan)

    #expect(results == [
        AxolotyCheckResult(
            name: "success",
            status: .passed,
            command: AxolotyCheckCommandResult(exitCode: 0, standardOutput: "success")
        ),
    ])
}

@Test
func commandRunnerStreamsHumanOutputWhileCapturingIt() {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-streaming-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let events = OutputEvents()
    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )
    let configuration = AxolotyCommandRunnerConfiguration(
        commandTimeout: 2,
        terminationGracePeriod: 0.2,
        heartbeatInterval: 0.05,
        outputMode: .human,
        artifactRoot: root,
        runID: "streaming",
        installSignalHandler: false,
        streamOutput: { stream, text in events.append(stream, text) }
    )
    let runner = FoundationCommandRunner(
        contextValidator: validator,
        environment: validator.environment,
        configuration: configuration
    )

    let result = runner.run(AxolotyCommandPlan(
        executable: "/bin/sh",
        arguments: ["-c", "printf 'out-one\\n'; printf 'err-one\\n' >&2; printf 'out-two\\n'"]
    ))

    #expect(result == AxolotyCheckCommandResult(
        exitCode: 0,
        standardOutput: "out-one\nout-two\n",
        standardError: "err-one\n"
    ))
    #expect(events.text(for: .standardOutput) == "out-one\nout-two\n")
    #expect(events.text(for: .standardError).contains("err-one\n"))
    #expect(events.text(for: .standardError).contains("heartbeat node=command stage=command"))
}

@Test
func commandRunnerKeepsJSONStdoutReservedForTheFinalResult() {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-json-output-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let events = OutputEvents()
    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )
    let configuration = AxolotyCommandRunnerConfiguration(
        commandTimeout: 2,
        heartbeatInterval: 0.05,
        outputMode: .json,
        artifactRoot: root,
        runID: "json-output",
        installSignalHandler: false,
        streamOutput: { stream, text in events.append(stream, text) }
    )
    let runner = FoundationCommandRunner(
        contextValidator: validator,
        environment: validator.environment,
        configuration: configuration
    )

    let result = runner.run(AxolotyCommandPlan(
        executable: "/bin/sh",
        arguments: ["-c", "printf 'json-child-output\\n'; printf 'json-progress\\n' >&2"]
    ))

    #expect(result.standardOutput == "json-child-output\n")
    #expect(events.text(for: .standardOutput).isEmpty)
    #expect(events.text(for: .standardError).contains("json-progress\n"))
    #expect(events.text(for: .standardError).contains("heartbeat node=command stage=command"))
}

@Test
func commandRunnerRejectsSwiftTestSuccessWhenNoTestsMatched() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-empty-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fakeSwift = root.appending(path: "swift")
    try """
    #!/bin/sh
    printf 'warning: No matching test cases were run\\n' >&2
    printf 'Test run with 0 tests in 0 suites passed after 0.001 seconds.\\n'
    exit 0
    """.write(to: fakeSwift, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSwift.path)

    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )
    let runner = FoundationCommandRunner(
        contextValidator: validator,
        environment: validator.environment,
        configuration: AxolotyCommandRunnerConfiguration(
            commandTimeout: 2,
            artifactRoot: root,
            runID: "empty-test",
            installSignalHandler: false
        )
    )

    let result = runner.run(AxolotyCommandPlan(
        executable: fakeSwift.path,
        arguments: ["test", "--filter", "MissingSuite"]
    ))

    #expect(result.exitCode == 65)
    #expect(result.standardError.contains("executed zero non-skipped tests"))
}

@Test
func commandRunnerRejectsSwiftTestSuccessWhenEverySelectedTestWasSkipped() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-skipped-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fakeSwift = root.appending(path: "swift")
    try """
    #!/bin/sh
    printf '➜ Test brokerScenario() skipped.\\n'
    printf '✔ Test run with 1 test in 1 suite passed after 0.001 seconds.\\n'
    exit 0
    """.write(to: fakeSwift, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSwift.path)

    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )
    let runner = FoundationCommandRunner(
        contextValidator: validator,
        environment: validator.environment,
        configuration: AxolotyCommandRunnerConfiguration(
            commandTimeout: 2,
            artifactRoot: root,
            runID: "skipped-tests",
            installSignalHandler: false
        )
    )

    let result = runner.run(AxolotyCommandPlan(
        executable: fakeSwift.path,
        arguments: ["test", "--filter", "BrokerScenario"]
    ))

    #expect(result.exitCode == 65)
    #expect(result.standardError.contains("executed zero non-skipped tests"))
}

@Test
func commandRunnerEscalatesTimeoutTracksLastTestAndPersistsSafeArtifacts() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-timeout-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let events = OutputEvents()
    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )
    let configuration = AxolotyCommandRunnerConfiguration(
        commandTimeout: 0.15,
        terminationGracePeriod: 0.05,
        heartbeatInterval: 0.02,
        outputMode: .json,
        artifactRoot: root,
        runID: "timeout",
        installSignalHandler: false,
        streamOutput: { stream, text in events.append(stream, text) }
    )
    let runner = FoundationCommandRunner(
        contextValidator: validator,
        environment: validator.environment,
        configuration: configuration
    )
    let command = AxolotyCommandPlan(
        executable: "/bin/sh",
        arguments: [
            "-c",
            "printf '◇ Test Lifecycle.test() started.\\n'; printf '%s\\n' \"$AXOLOTY_SECRET\"; trap '' TERM; sleep 10",
        ],
        environment: ["AXOLOTY_SECRET": "timeout-secret"]
    )

    let result = runner.run(command, context: AxolotyCommandRunContext(node: "test-tooling", stage: "check"))
    let lifecycle = try #require(result.lifecycle)
    #expect(result.exitCode == 124)
    #expect(lifecycle.outcome == .timedOut)
    #expect(lifecycle.node == "test-tooling")
    #expect(lifecycle.stage == "check")
    #expect(lifecycle.lastTest == "◇ Test Lifecycle.test() started.")
    #expect(lifecycle.escalatedToKill)
    #expect(events.text(for: .standardOutput).isEmpty)
    #expect(events.text(for: .standardError).contains("heartbeat node=test-tooling stage=check"))
    #expect(events.text(for: .standardError).contains("output-bytes="))

    let artifact = try #require(lifecycle.artifactPath)
    let artifactDirectory = URL(fileURLWithPath: artifact)
    #expect(FileManager.default.fileExists(atPath: artifactDirectory.appending(path: "metadata.json").path))
    #expect(FileManager.default.fileExists(atPath: artifactDirectory.appending(path: "manifest.json").path))
    #expect(FileManager.default.fileExists(atPath: artifactDirectory.appending(path: "verifier.log").path))
    #expect(FileManager.default.fileExists(atPath: artifactDirectory.appending(path: "stdout.txt").path))
    #expect(FileManager.default.fileExists(atPath: artifactDirectory.appending(path: "stderr.txt").path))
    #expect(FileManager.default.fileExists(atPath: artifactDirectory.appending(path: "result.json").path))
    let durableOutput = try String(contentsOf: artifactDirectory.appending(path: "stdout.txt"), encoding: .utf8)
    #expect(!durableOutput.contains("timeout-secret"))
    let metadata = try JSONSerialization.jsonObject(
        with: Data(contentsOf: artifactDirectory.appending(path: "metadata.json"))
    ) as? [String: Any]
    #expect(metadata?["environmentKeys"] as? [String] == ["AXOLOTY_DEVCONTAINER", "AXOLOTY_SECRET"])
    #expect(metadata?["exitCode"] as? Int == 124)
    let manifest = try JSONSerialization.jsonObject(
        with: Data(contentsOf: artifactDirectory.appending(path: "manifest.json"))
    ) as? [String: Any]
    #expect(manifest?["status"] as? String == "failed")
    #expect(manifest?["outcome"] as? String == "timedOut")
    let verifier = try String(
        contentsOf: artifactDirectory.appending(path: "verifier.log"),
        encoding: .utf8
    )
    #expect(verifier.contains("[progress]"))
    #expect(verifier.contains("[stderr]"))
    #expect(verifier.contains("heartbeat node=test-tooling"))
    #expect(verifier.contains("command timed out"))
    #expect(!verifier.contains("timeout-secret"))
}

@Test
func commandRunnerDrainsTermTrapTailBeforeCancellingReaders() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-term-tail-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )
    let runner = FoundationCommandRunner(
        contextValidator: validator,
        environment: validator.environment,
        configuration: AxolotyCommandRunnerConfiguration(
            // Coverage instrumentation and a loaded CI runner can delay the
            // child shell before it installs its TERM trap. Keep enough
            // margin for setup so this test measures reader draining.
            commandTimeout: 1,
            terminationGracePeriod: 1,
            heartbeatInterval: 1,
            artifactRoot: root,
            runID: "term-tail",
            installSignalHandler: false
        )
    )
    let result = runner.run(AxolotyCommandPlan(
        executable: "/bin/sh",
        arguments: [
            "-c",
            "trap 'printf \"TERM-TRAP-TAIL\\n\" >&2; trap - TERM; sleep 10' TERM; while :; do sleep 1; done",
        ]
    ))

    let lifecycle = try #require(result.lifecycle)
    #expect(lifecycle.outcome == .timedOut)
    #expect(result.standardError.contains("TERM-TRAP-TAIL"))
    let artifact = try #require(lifecycle.artifactPath)
    let artifactDirectory = URL(fileURLWithPath: artifact)
    let durableError = try String(
        contentsOf: artifactDirectory.appending(path: "stderr.txt"),
        encoding: .utf8
    )
    let verifier = try String(
        contentsOf: artifactDirectory.appending(path: "verifier.log"),
        encoding: .utf8
    )
    #expect(durableError.contains("TERM-TRAP-TAIL"))
    #expect(verifier.contains("TERM-TRAP-TAIL"))
}

@Test
func commandRunnerTerminatesExecutableDescendantsWithoutLeavingOrphans() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-process-tree-\(UUID().uuidString)")
    let childPIDFile = root.appending(path: "child.pid")
    let childExitedMarker = root.appending(path: "child-exited")
    let childScriptURL = root.appending(path: "child.sh")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try """
    #!/bin/sh
    trap 'printf exited > "\(childExitedMarker.path)"; exit 0' TERM INT
    while :; do sleep 1; done
    """.write(to: childScriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: childScriptURL.path)
    defer {
        if let data = try? Data(contentsOf: childPIDFile),
           let pid = Int32(String(decoding: data, as: UTF8.self)) {
            _ = kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: root)
    }

    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )
    let runner = FoundationCommandRunner(
        contextValidator: validator,
        environment: validator.environment,
        configuration: AxolotyCommandRunnerConfiguration(
            commandTimeout: 0.25,
            terminationGracePeriod: 1,
            heartbeatInterval: 1,
            artifactRoot: root,
            runID: "process-tree",
            installSignalHandler: false
        )
    )
    let commandScript = """
        \(childScriptURL.path) &
        child=$!
        printf '%s' "$child" > '\(childPIDFile.path)'
        trap 'wait "$child"; exit 143' TERM INT
        wait "$child"
    """

    let result = runner.run(AxolotyCommandPlan(
        executable: "/bin/sh",
        arguments: ["-c", commandScript]
    ))

    let childPIDData = try Data(contentsOf: childPIDFile)
    let childPID = try #require(Int32(String(decoding: childPIDData, as: UTF8.self)))
    #expect(result.lifecycle?.outcome == .timedOut)
    #expect(waitForFile(childExitedMarker))
    #expect(!processIsAlive(childPID))
}

@Test
func commandRunnerRejectsInvalidPerCommandTimeoutBeforeLaunching() {
    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )
    let runner = FoundationCommandRunner(
        contextValidator: validator,
        environment: validator.environment,
        configuration: AxolotyCommandRunnerConfiguration(
            commandTimeout: 1,
            artifactRoot: FileManager.default.temporaryDirectory,
            installSignalHandler: false
        )
    )

    let result = runner.run(AxolotyCommandPlan(executable: "/bin/false", timeoutSeconds: 9_000_000_001))

    #expect(result.exitCode == 64)
    let diagnostic = try? JSONSerialization.jsonObject(
        with: Data(result.standardError.utf8)
    ) as? [String: String]
    #expect(diagnostic?["option"] == "commandTimeout")
    #expect(diagnostic?["reason"] == "is too large")
}

@Test
func commandRunnerResolvesExecutableUsingCommandSpecificPath() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-command-path-\(UUID().uuidString)")
    let executable = root.appending(path: "path-command")
    let artifactRoot = root.appending(path: "artifacts")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "#!/bin/sh\nprintf path-command-ok\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let environment = ["AXOLOTY_DEVCONTAINER": "1", "PATH": "/usr/bin:/bin"]
    let validator = AxolotyExecutionContextValidator(environment: environment, platform: .linux)
    let runner = FoundationCommandRunner(
        contextValidator: validator,
        environment: environment,
        configuration: AxolotyCommandRunnerConfiguration(
            commandTimeout: 1,
            artifactRoot: artifactRoot,
            runID: "path",
            installSignalHandler: false
        )
    )

    let result = runner.run(AxolotyCommandPlan(
        executable: "path-command",
        environment: ["PATH": root.path]
    ))

    #expect(result == AxolotyCheckCommandResult(exitCode: 0, standardOutput: "path-command-ok"))
}

@Test
func artifactRedactionHandlesOverlappingShortSecretsAndKnownOptions() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-redaction-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = [
        "AXOLOTY_DEVCONTAINER": "1",
        "AXOLOTY_TOKEN": "abc",
        "AXOLOTY_PASSWORD": "abcdef",
        "AXOLOTY_SHORT_SECRET": "xy",
    ]
    let validator = AxolotyExecutionContextValidator(environment: environment, platform: .linux)
    let runner = FoundationCommandRunner(
        contextValidator: validator,
        environment: environment,
        configuration: AxolotyCommandRunnerConfiguration(
            commandTimeout: 1,
            artifactRoot: root,
            runID: "redaction",
            installSignalHandler: false
        )
    )

    let result = runner.run(AxolotyCommandPlan(
        executable: "/bin/echo",
        arguments: ["--password", "cli-value", "--token=embedded", "abcdef", "xy"]
    ))

    #expect(result.exitCode == 0)
    let artifactDirectory = root.appending(path: "redaction/001-command")
    let durableOutput = try String(
        contentsOf: artifactDirectory.appending(path: "stdout.txt"),
        encoding: .utf8
    )
    #expect(!durableOutput.contains("abc"))
    #expect(!durableOutput.contains("cli-value"))
    #expect(!durableOutput.contains("embedded"))
    #expect(!durableOutput.contains("xy"))

    let metadata = try #require(JSONSerialization.jsonObject(
        with: Data(contentsOf: artifactDirectory.appending(path: "metadata.json"))
    ) as? [String: Any])
    #expect(metadata["arguments"] as? [String] == [
        "--password", "<redacted>", "--token=<redacted>", "<redacted>", "<redacted>",
    ])
}

@Test
func runnerConfigurationRejectsMalformedNegativeAndOversizedTimeouts() {
    for value in ["not-a-number", "-1", "nan", "9000000001"] {
        let configuration = AxolotyCommandRunnerConfiguration.from(environment: [
            "AXOLOTY_COMMAND_TIMEOUT_SECONDS": value,
        ])
        #expect(configuration.validationDiagnostic != nil)
    }
}

@Test
func runnerConfigurationAllowsZeroTimeoutAsUnlimited() {
    let configuration = AxolotyCommandRunnerConfiguration.from(environment: [
        "AXOLOTY_COMMAND_TIMEOUT_SECONDS": "0",
    ])

    #expect(configuration.commandTimeout == nil)
    #expect(configuration.validationDiagnostic == nil)
}

@Test
func commandRunnerCancellationIsOwnedByTheRunner() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-cancel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )
    let cancellation = AxolotyCommandCancellation()
    cancellation.cancel()
    let runner = FoundationCommandRunner(
        contextValidator: validator,
        environment: validator.environment,
        configuration: AxolotyCommandRunnerConfiguration(
            commandTimeout: nil,
            artifactRoot: root,
            runID: "cancelled",
            installSignalHandler: false
        ),
        cancellation: cancellation
    )

    let result = runner.run(
        AxolotyCommandPlan(executable: "/bin/sh", arguments: ["-c", "exit 0"]),
        context: AxolotyCommandRunContext(node: "cancelled-node", stage: "check")
    )

    #expect(result.exitCode == 130)
    #expect(result.lifecycle?.outcome == .cancelled)
    #expect(result.lifecycle?.node == "cancelled-node")
}

@Test
func commandRunnerCancelsAndReapsAnActiveProcessGroup() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-active-cancel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )
    let runner = FoundationCommandRunner(
        contextValidator: validator,
        environment: validator.environment,
        configuration: AxolotyCommandRunnerConfiguration(
            commandTimeout: nil,
            terminationGracePeriod: 0.05,
            artifactRoot: root,
            runID: "active-cancelled",
            installSignalHandler: false
        )
    )
    let resultBox = CommandResultBox()
    let completion = DispatchGroup()
    completion.enter()
    DispatchQueue.global(qos: .utility).async {
        resultBox.store(runner.run(
            AxolotyCommandPlan(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; sleep 10"]
            ),
            context: AxolotyCommandRunContext(node: "active-cancel", stage: "check")
        ))
        completion.leave()
    }
    Thread.sleep(forTimeInterval: 0.1)
    runner.cancel()

    #expect(completion.wait(timeout: .now() + .seconds(2)) == .success)
    let result = try #require(resultBox.result)
    #expect(result.exitCode == 130)
    #expect(result.lifecycle?.outcome == .cancelled)
    #expect(result.lifecycle?.node == "active-cancel")
}

@Test
func artifactStoreRejectsTraversalAndUnsafeSymlinkRoots() throws {
    let base = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-artifact-safety-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let environment = ["AXOLOTY_DEVCONTAINER": "1", "AXOLOTY_SECRET": "s"]
    let traversal = FoundationCommandRunner(
        contextValidator: AxolotyExecutionContextValidator(environment: environment, platform: .linux),
        environment: environment,
        configuration: AxolotyCommandRunnerConfiguration(
            commandTimeout: 1,
            artifactRoot: base,
            runID: "../escape",
            installSignalHandler: false
        )
    )
    #expect(traversal.run(AxolotyCommandPlan(executable: "/bin/true")).exitCode == 70)

    let outside = base.appending(path: "outside")
    try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let rootLink = base.appending(path: "root-link")
    try? FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: outside)
    let symlinkRunner = FoundationCommandRunner(
        contextValidator: AxolotyExecutionContextValidator(environment: environment, platform: .linux),
        environment: environment,
        configuration: AxolotyCommandRunnerConfiguration(
            commandTimeout: 1,
            artifactRoot: rootLink,
            runID: "safe",
            installSignalHandler: false
        )
    )
    #expect(symlinkRunner.run(AxolotyCommandPlan(executable: "/bin/true")).exitCode == 70)
}

final class BridgeCapabilityFixture {
    let directory: URL
    let runtime: URL
    let socket: URL
    private let socketServer: Process

    private func stopSocketServer() {
        guard socketServer.isRunning else { return }
        _ = kill(socketServer.processIdentifier, SIGTERM)
        let termDeadline = Date().addingTimeInterval(1)
        while socketServer.isRunning && Date() < termDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if socketServer.isRunning {
            _ = kill(socketServer.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(1)
            while socketServer.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        guard !socketServer.isRunning else {
            Issue.record("socket helper process \(socketServer.processIdentifier) did not exit after bounded TERM/KILL cleanup")
            return
        }
        socketServer.waitUntilExit()
    }

    var environment: [String: String] {
        [
            "AXOLOTY_DEVCONTAINER": "1",
            "AXOLOTY_HOST_RUNTIME_BRIDGE": "1",
            "CONTAINER_RUNTIME": runtime.path,
            "DOCKER_HOST": "unix://\(socket.path)",
        ]
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "axoloty-tool-bridge-\(UUID().uuidString)", directoryHint: .isDirectory)
        runtime = directory.appending(path: "container-runtime-remote.sh")
        socket = directory.appending(path: "podman.sock")
        socketServer = Process()

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: runtime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)

        socketServer.executableURL = URL(filePath: "/usr/bin/env")
        socketServer.arguments = [
            "python3", "-c",
            "import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(60)",
            socket.path,
        ]
        socketServer.standardOutput = FileHandle.nullDevice
        socketServer.standardError = FileHandle.nullDevice
        try socketServer.run()

        for _ in 0..<100 {
            let attributes = try? FileManager.default.attributesOfItem(atPath: socket.path)
            if (attributes?[.type] as? FileAttributeType) == .typeSocket { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        stopSocketServer()
        try? FileManager.default.removeItem(at: directory)
        throw CocoaError(.fileNoSuchFile)
    }

    deinit {
        stopSocketServer()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func contextMarker(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-\(label)-\(UUID().uuidString)")
}

private func markerCommand(
    _ marker: URL,
    executionContext: AxolotyCommandPlan.ExecutionContext
) -> AxolotyCommandPlan {
    AxolotyCommandPlan(
        executable: "/bin/sh",
        arguments: ["-c", "touch \(marker.path)"],
        executionContext: executionContext
    )
}

@Test
func projectCommandRunsInProjectContext() {
    let marker = contextMarker("project-in-project")
    defer { try? FileManager.default.removeItem(at: marker) }
    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )

    let result = FoundationCommandRunner(contextValidator: validator).run(
        markerCommand(marker, executionContext: .project)
    )

    #expect(result == AxolotyCheckCommandResult(exitCode: 0))
    #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test
func hostCommandIsRejectedInProjectContextBeforeStartingProcess() throws {
    let marker = contextMarker("host-in-project")
    defer { try? FileManager.default.removeItem(at: marker) }
    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )

    let result = FoundationCommandRunner(contextValidator: validator).run(
        markerCommand(marker, executionContext: .host)
    )

    #expect(result.exitCode == 64)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    let diagnostic = try JSONDecoder().decode(
        AxolotyExecutionContextDiagnostic.self,
        from: Data(result.standardError.utf8)
    )
    #expect(diagnostic == AxolotyExecutionContextDiagnostic(
        executable: "/bin/sh",
        declaredContext: .host,
        detectedContext: .project
    ))
}

@Test
func hostCommandRunsInObservableBridgeAndPropagatesEnvironment() throws {
    let bridge = try BridgeCapabilityFixture()
    let validator = AxolotyExecutionContextValidator(
        environment: bridge.environment,
        platform: .linux
    )

    let result = FoundationCommandRunner(contextValidator: validator).run(
        AxolotyCommandPlan(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "printf '%s\\n' \"$AXOLOTY_DEVCONTAINER\" \"$AXOLOTY_HOST_RUNTIME_BRIDGE\" \"$CONTAINER_RUNTIME\" \"$DOCKER_HOST\"",
            ],
            executionContext: .host
        )
    )

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.split(separator: "\n").map(String.init) == [
        "1",
        "1",
        bridge.runtime.path,
        "unix://\(bridge.socket.path)",
    ])
}

private func expectBridgeRejection(
    environment: [String: String],
    label: String
) throws {
    let marker = contextMarker(label)
    defer { try? FileManager.default.removeItem(at: marker) }
    let validator = AxolotyExecutionContextValidator(environment: environment, platform: .linux)

    let result = FoundationCommandRunner(contextValidator: validator).run(
        markerCommand(marker, executionContext: .host)
    )

    #expect(result.exitCode == 64)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(try JSONDecoder().decode(
        AxolotyExecutionContextDiagnostic.self,
        from: Data(result.standardError.utf8)
    ) == AxolotyExecutionContextDiagnostic(
        executable: "/bin/sh",
        declaredContext: .host,
        detectedContext: .project
    ))
}

@Test
func bridgeMarkersRejectMissingRuntimeBeforeStartingProcess() throws {
    let bridge = try BridgeCapabilityFixture()
    var environment = bridge.environment
    environment["CONTAINER_RUNTIME"] = bridge.directory.appending(path: "missing-runtime").path
    try expectBridgeRejection(environment: environment, label: "bridge-missing-runtime")
}

@Test
func bridgeMarkersRejectMissingSocketBeforeStartingProcess() throws {
    let bridge = try BridgeCapabilityFixture()
    var environment = bridge.environment
    let missingSocket = bridge.directory.appending(path: "missing.sock").path
    environment["DOCKER_HOST"] = "unix://\(missingSocket)"
    try expectBridgeRejection(environment: environment, label: "bridge-missing-socket")
}

@Test
func bridgeMarkersRejectRegularFileSocketPathBeforeStartingProcess() throws {
    let bridge = try BridgeCapabilityFixture()
    let regularFile = bridge.directory.appending(path: "not-a-socket")
    try Data().write(to: regularFile)
    var environment = bridge.environment
    environment["DOCKER_HOST"] = "unix://\(regularFile.path)"
    try expectBridgeRejection(environment: environment, label: "bridge-regular-file")
}

@Test
func commandRunnerAllowsHostCommandInHostContext() {
    let marker = contextMarker("host-in-host")
    defer { try? FileManager.default.removeItem(at: marker) }
    let validator = AxolotyExecutionContextValidator(environment: [:], platform: .linux)

    let result = FoundationCommandRunner(contextValidator: validator).run(
        markerCommand(marker, executionContext: .host)
    )

    #expect(result == AxolotyCheckCommandResult(exitCode: 0))
    #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test
func projectCommandIsRejectedInLinuxHostContextBeforeStartingProcess() throws {
    let marker = contextMarker("project-in-host")
    defer { try? FileManager.default.removeItem(at: marker) }
    let validator = AxolotyExecutionContextValidator(environment: [:], platform: .linux)

    let result = FoundationCommandRunner(contextValidator: validator).run(
        markerCommand(marker, executionContext: .project)
    )

    #expect(result.exitCode == 64)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    let diagnostic = try JSONDecoder().decode(
        AxolotyExecutionContextDiagnostic.self,
        from: Data(result.standardError.utf8)
    )
    #expect(diagnostic == AxolotyExecutionContextDiagnostic(
        executable: "/bin/sh",
        declaredContext: .project,
        detectedContext: .host
    ))
}

@Test
func projectCommandRunsInNativeMacOSContext() {
    let marker = contextMarker("project-in-native-macos")
    defer { try? FileManager.default.removeItem(at: marker) }
    let validator = AxolotyExecutionContextValidator(environment: [:], platform: .macOS)

    let result = FoundationCommandRunner(contextValidator: validator).run(
        markerCommand(marker, executionContext: .project)
    )

    #expect(result == AxolotyCheckCommandResult(exitCode: 0))
    #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test
func executorValidatesEveryContextBeforeStartingAnyCommand() throws {
    let marker = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-plan-context-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: marker) }
    let plan = AxolotyCheckPlan(nodes: [
        AxolotyCheckNode(name: "valid", command: AxolotyCommandPlan(executable: "/bin/sh", arguments: ["-c", "touch \(marker.path)"], executionContext: .project)),
        AxolotyCheckNode(name: "invalid", command: AxolotyCommandPlan(executable: "/bin/sh", arguments: ["-c", "true"], executionContext: .host)),
    ])

    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )
    let results = AxolotyCheckExecutor(
        commandRunner: FoundationCommandRunner(contextValidator: validator),
        contextValidator: validator
    ).execute(plan)

    #expect(results.map(\.status) == [.skipped, .failed])
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    let diagnostic = try #require(results[1].command?.standardError.data(using: .utf8))
    #expect(try JSONDecoder().decode(AxolotyExecutionContextDiagnostic.self, from: diagnostic) ==
        AxolotyExecutionContextDiagnostic(
            executable: "/bin/sh",
            declaredContext: .host,
            detectedContext: .project
        ))
}
