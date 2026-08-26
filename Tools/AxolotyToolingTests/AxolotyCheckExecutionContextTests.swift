// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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

extension AxolotyCheckTests {

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

}
