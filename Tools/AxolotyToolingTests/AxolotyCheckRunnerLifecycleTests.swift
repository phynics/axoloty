// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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

extension AxolotyCheckTests {

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

    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "out-one\nout-two\n")
    #expect(result.standardError == "err-one\n")
    #expect(result.lifecycle == nil)
    #expect(result.observation?.outputBytes == 24)
    #expect(result.observation?.artifactPath.contains("/invocations/") == true)
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

    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "path-command-ok")
    #expect(result.observation?.outputBytes == 15)
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

}
