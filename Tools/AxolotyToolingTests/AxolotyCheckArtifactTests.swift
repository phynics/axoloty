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
