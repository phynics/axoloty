// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

@Suite("AxolotyCommandProgressOutputTests")
struct AxolotyCommandProgressOutputTests {
    private final class OutputRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(stream: AxolotyCommandOutputStream, text: String)] = []

        func append(_ stream: AxolotyCommandOutputStream, _ text: String) {
            lock.lock()
            events.append((stream, text))
            lock.unlock()
        }

        func text(for stream: AxolotyCommandOutputStream) -> String {
            lock.lock()
            defer { lock.unlock() }
            return events.filter { $0.stream == stream }.map(\.text).joined()
        }

        var all: String {
            lock.lock()
            defer { lock.unlock() }
            return events.map(\.text).joined()
        }
    }

    private static func validator() -> AxolotyExecutionContextValidator {
        AxolotyExecutionContextValidator(
            environment: ["AXOLOTY_DEVCONTAINER": "1"],
            platform: .linux
        )
    }

    private static func temporaryArtifactRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "axoloty-progress-\(label)-\(UUID().uuidString)")
    }

    private func makeRunner(
        outputMode: AxolotyCommandOutputMode,
        recorder: OutputRecorder,
        root: URL,
        commandTimeout: TimeInterval? = 5
    ) -> FoundationCommandRunner {
        let runnerConfiguration = AxolotyCommandRunnerConfiguration(
            commandTimeout: commandTimeout,
            terminationGracePeriod: 0.2,
            heartbeatInterval: 0.05,
            outputMode: outputMode,
            interactiveOutput: false,
            artifactRoot: root,
            runID: "progress",
            installSignalHandler: false,
            streamOutput: { stream, text in recorder.append(stream, text) }
        )
        return FoundationCommandRunner(
            contextValidator: Self.validator(),
            environment: Self.validator().environment,
            configuration: runnerConfiguration
        )
    }

    @Test
    func progressModeParsesBuildProgressWithoutRawSpam() {
        let recorder = OutputRecorder()
        let root = Self.temporaryArtifactRoot("build")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(outputMode: .progress, recorder: recorder, root: root)
        let result = runner.run(
            AxolotyCommandPlan(
                executable: "/bin/sh",
                arguments: ["-c", """
                echo '[84/217] Compiling Axoloty MQTTClient.swift'
                echo '[205/217] Linking AxolotyTests'
                echo 'Build complete!'
                """]
            ),
            context: AxolotyCommandRunContext(node: "build", stage: "check")
        )
        #expect(result.exitCode == 0)
        let emitted = recorder.all
        #expect(emitted.contains("[build] compiling Axoloty 84/217"))
        #expect(emitted.contains("[build] linking AxolotyTests"))
        #expect(emitted.contains("[build] passed"))
        #expect(!emitted.contains("Build complete!"))
        #expect(!emitted.contains("\u{1B}"))
    }

    @Test
    func progressModeFormatsCompilerFailureWithoutReplacingArtifacts() throws {
        let recorder = OutputRecorder()
        let root = Self.temporaryArtifactRoot("failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(outputMode: .progress, recorder: recorder, root: root)
        let result = runner.run(
            AxolotyCommandPlan(
                executable: "/bin/sh",
                arguments: ["-c", """
                echo '[84/217] Compiling Axoloty MQTTClient.swift'
                echo "Sources/Axoloty/MQTT/Broker.swift:84:21: error: value of type 'MQTTClient' has no member 'connect'" >&2
                echo ' 84 | client.connect()' >&2
                echo '    |        ^~~~~~~' >&2
                exit 1
                """]
            ),
            context: AxolotyCommandRunContext(node: "build", stage: "check")
        )
        #expect(result.exitCode == 1)
        let emitted = recorder.all
        #expect(emitted.contains("[build] failed"))
        #expect(emitted.contains("Broker.swift:84:21"))
        #expect(emitted.contains("error: value of type 'MQTTClient' has no member 'connect'"))
        #expect(emitted.contains("^~~~~~~"))
        #expect(emitted.contains("trace:"))
        #expect(emitted.contains("sh -c"))
        #expect(emitted.contains("full log:"))
        #expect(!emitted.contains("\u{1B}"))

        // Raw evidence remains authoritative in artifacts.
        let artifactDirectory = try #require(result.observation?.artifactPath)
        let standardOutput = try String(contentsOf: URL(filePath: artifactDirectory + "/stdout.txt"), encoding: .utf8)
        let standardError = try String(contentsOf: URL(filePath: artifactDirectory + "/stderr.txt"), encoding: .utf8)
        #expect(standardOutput.contains("[84/217] Compiling Axoloty MQTTClient.swift"))
        #expect(standardError.contains("Broker.swift:84:21: error:"))
        let durableResult = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(filePath: artifactDirectory + "/result.json"))
        ) as? [String: Any]
        #expect(durableResult?["exitCode"] as? Int == 1)
    }

    @Test
    func progressModeFailureWithoutRecognizedDiagnosticsKeepsBoundedTail() {
        let recorder = OutputRecorder()
        let root = Self.temporaryArtifactRoot("opaque")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(outputMode: .progress, recorder: recorder, root: root)
        let result = runner.run(
            AxolotyCommandPlan(
                executable: "/bin/sh",
                arguments: ["-c", "echo 'opaque failure text' >&2; exit 3"]
            ),
            context: AxolotyCommandRunContext(node: "opaque", stage: "check")
        )
        #expect(result.exitCode == 3)
        let emitted = recorder.all
        #expect(emitted.contains("Unable to extract structured compiler diagnostics."))
        #expect(emitted.contains("opaque failure text"))
        #expect(emitted.contains("full log:"))
    }

    @Test
    func rawModeForwardsChildStreams() {
        let recorder = OutputRecorder()
        let root = Self.temporaryArtifactRoot("raw")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(outputMode: .raw, recorder: recorder, root: root)
        let result = runner.run(AxolotyCommandPlan(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'out-one\\n'; printf 'err-one\\n' >&2"]
        ))
        #expect(result.exitCode == 0)
        #expect(recorder.text(for: .standardOutput) == "out-one\n")
        #expect(recorder.text(for: .standardError).contains("err-one"))
    }

    @Test
    func jsonModeKeepsStdoutReservedAndAvoidsANSI() {
        let recorder = OutputRecorder()
        let root = Self.temporaryArtifactRoot("json")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(outputMode: .json, recorder: recorder, root: root)
        let result = runner.run(AxolotyCommandPlan(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'out-one\\n'; printf 'err-one\\n' >&2"]
        ))
        #expect(result.exitCode == 0)
        #expect(recorder.text(for: .standardOutput).isEmpty)
        #expect(!recorder.all.contains("\u{1B}"))
        #expect(recorder.all.contains("err-one"))
    }

    @Test
    func timedOutBuildStillShowsProgressAndPreservesLifecycle() {
        let recorder = OutputRecorder()
        let root = Self.temporaryArtifactRoot("timeout")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(
            outputMode: .progress,
            recorder: recorder,
            root: root,
            commandTimeout: 0.4
        )
        let result = runner.run(
            AxolotyCommandPlan(
                executable: "/bin/sh",
                arguments: ["-c", "echo '[1/2] Compiling Axoloty A.swift'; sleep 30"]
            ),
            context: AxolotyCommandRunContext(node: "build", stage: "check")
        )
        #expect(result.exitCode == 124)
        #expect(result.lifecycle?.outcome == .timedOut)
        #expect(recorder.all.contains("[build] compiling Axoloty 1/2"))
        #expect(recorder.all.contains("[build] failed"))
        #expect(recorder.all.contains("timed out"))
    }

    @Test
    func outputModeEnvironmentMappings() {
        #expect(AxolotyCommandRunnerConfiguration.from(environment: ["AXOLOTY_OUTPUT": "human"]).outputMode == .raw)
        #expect(AxolotyCommandRunnerConfiguration.from(environment: ["AXOLOTY_OUTPUT": "progress"]).outputMode == .progress)
        #expect(AxolotyCommandRunnerConfiguration.from(environment: ["AXOLOTY_OUTPUT": "json"]).outputMode == .json)
        #expect(AxolotyCommandRunnerConfiguration.from(environment: ["AXOLOTY_TOOL_OUTPUT": "human"]).outputMode == .raw)
        #expect(AxolotyCommandRunnerConfiguration.from(environment: ["AXOLOTY_PROGRESS": "1"]).outputMode == .progress)
        #expect(AxolotyCommandRunnerConfiguration.from(environment: [:]).outputMode == .json)
    }

    @Test
    func unknownOutputStillAdvancesThroughFallbackAndCompletion() {
        let recorder = OutputRecorder()
        let root = Self.temporaryArtifactRoot("unknown")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(outputMode: .progress, recorder: recorder, root: root)
        let result = runner.run(AxolotyCommandPlan(
            executable: "/bin/sh",
            arguments: ["-c", "echo 'totally unrecognized long output'; sleep 0.3"]
        ))
        #expect(result.exitCode == 0)
        let emitted = recorder.all
        #expect(emitted.contains("[command] sh -c started"))
        #expect(emitted.contains("passed"))
        #expect(!emitted.contains("totally unrecognized long output"))
    }
}
