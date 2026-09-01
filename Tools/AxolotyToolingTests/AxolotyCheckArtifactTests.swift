// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

extension AxolotyCheckTests {

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
    let artifactDirectory = try #require(commandArtifactDirectories(in: root.appending(path: "redaction")).first)
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
func artifactStoreSeparatesConcurrentInvocationsWithTheSameRunID() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-artifact-invocations-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = ["AXOLOTY_DEVCONTAINER": "1"]
    let validator = AxolotyExecutionContextValidator(environment: environment, platform: .linux)
    func makeRunner() -> FoundationCommandRunner {
        FoundationCommandRunner(
            contextValidator: validator,
            environment: environment,
            configuration: AxolotyCommandRunnerConfiguration(
                commandTimeout: 2,
                artifactRoot: root,
                runID: "shared",
                installSignalHandler: false
            )
        )
    }
    let first = makeRunner()
    let second = makeRunner()

    let exitCodes = await withTaskGroup(of: Int32.self, returning: [Int32].self) { group in
        group.addTask { first.run(AxolotyCommandPlan(executable: "/bin/true")).exitCode }
        group.addTask { second.run(AxolotyCommandPlan(executable: "/bin/true")).exitCode }
        var values: [Int32] = []
        for await value in group { values.append(value) }
        return values
    }

    #expect(exitCodes.sorted() == [0, 0])
    let invocations = try invocationDirectories(in: root.appending(path: "shared"))
    #expect(invocations.count == 2)
    for invocation in invocations {
        #expect(FileManager.default.fileExists(atPath: invocation.appending(path: "invocation.json").path))
        #expect(commandArtifactDirectories(in: invocation).count == 1)
    }
}

@Test
func commandRunnerPassesItsInvocationIDToChildProcesses() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-tool-artifact-parent-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = ["AXOLOTY_DEVCONTAINER": "1"]
    let validator = AxolotyExecutionContextValidator(environment: environment, platform: .linux)
    let runner = FoundationCommandRunner(
        contextValidator: validator,
        environment: environment,
        configuration: AxolotyCommandRunnerConfiguration(
            commandTimeout: 2,
            artifactRoot: root,
            runID: "parent",
            installSignalHandler: false
        )
    )

    let result = runner.run(AxolotyCommandPlan(
        executable: "/bin/sh",
        arguments: ["-c", "printf '%s' \"$AXOLOTY_PARENT_INVOCATION_ID\""]
    ))

    let invocation = try #require(invocationDirectories(in: root.appending(path: "parent")).first)
    let metadata = try #require(JSONSerialization.jsonObject(
        with: Data(contentsOf: invocation.appending(path: "invocation.json"))
    ) as? [String: Any])
    #expect(result.standardOutput == metadata["invocationId"] as? String)
    #expect(metadata["parentInvocationId"] is NSNull)
}

private func invocationDirectories(in runDirectory: URL) throws -> [URL] {
    let directory = runDirectory.appending(path: "invocations")
    return try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey]
    ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
}

private func commandArtifactDirectories(in root: URL) -> [URL] {
    let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey]
    )
    return (enumerator?.allObjects as? [URL] ?? []).filter { directory in
        (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && FileManager.default.fileExists(atPath: directory.appending(path: "manifest.json").path)
    }
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

}
