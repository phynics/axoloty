// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

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
        withExtension: "json",
        subdirectory: "Fixtures"
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
    #expect(plan.nodes.map(\.name).suffix(2) == ["embedded-build", "embedded-linker"])
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

final class BridgeCapabilityFixture {
    let directory: URL
    let runtime: URL
    let socket: URL
    private let socketServer: Process

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
        socketServer.terminate()
        socketServer.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
        throw CocoaError(.fileNoSuchFile)
    }

    deinit {
        if socketServer.isRunning {
            socketServer.terminate()
            socketServer.waitUntilExit()
        }
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
