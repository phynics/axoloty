// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

@Test
func repositoryAuthorityPassesForCheckout() {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let report = AxolotyRepositoryAuthorityValidator(root: root).validate()

    #expect(report.status == "passed")
    #expect(report.version == "0.5.1")
}

@Test
func repositoryAuthorityCommandSupportsHumanAndJSONOutput() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let dispatcher = AxolotyCommandDispatcher(
        repositoryRoot: root,
        installSignalHandler: false
    )

    let human = dispatcher.run(arguments: ["repository", "validate"])
    #expect(human.exitCode == 0)
    #expect(human.standardOutput == "repository authority: passed\n")

    let json = dispatcher.run(arguments: ["repository", "validate", "--format", "json"])
    #expect(json.exitCode == 0)
    let report = try JSONDecoder().decode(
        AxolotyRepositoryAuthorityReport.self,
        from: Data(json.standardOutput.utf8)
    )
    #expect(report.status == "passed")
    #expect(report.findings.isEmpty)
}

@Test
func repositoryAuthorityRejectsVersionDriftAndNonWaivableExceptions() throws {
    let fixture = try makeAuthorityFixture(
        makefileVersion: "0.5.0",
        exception: """
        {"schemaVersion":1,"exceptions":[{"id":"E-1","invariant":"INV-001","paths":["Tools/X.swift"],"reason":"probe","ownerIssue":"#629","owner":"team","compensatingTests":["probe"],"introducedDate":"2026-08-20","expiry":{"kind":"release","value":"0.6.0"},"removalCondition":"remove after G1"}]}
        """
    )
    defer { try? FileManager.default.removeItem(at: fixture) }

    let report = AxolotyRepositoryAuthorityValidator(root: fixture).validate()
    #expect(report.status == "failed")
    #expect(report.findings.contains { $0.rule == "version.claim" && $0.path == "Makefile" })
    #expect(report.findings.contains { $0.rule == "exceptions.non-waivable" })
}

@Test
func repositoryAuthorityIgnoresHistoricalVersionClaims() throws {
    let fixture = try makeAuthorityFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let historical = fixture.appendingPathComponent("docs/releases/0.4.md")
    try FileManager.default.createDirectory(at: historical.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("# Axoloty 0.4.0 release notes\n".utf8).write(to: historical)

    let report = AxolotyRepositoryAuthorityValidator(root: fixture).validate()
    #expect(report.status == "passed")
}

private func makeAuthorityFixture(
    makefileVersion: String = "0.5.1",
    exception: String = "{\"schemaVersion\":1,\"exceptions\":[]}"
) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-authority-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let files: [String: String] = [
        "VERSION": "0.5.1\n",
        "README.md": "# Axoloty\n.package(url: \"https://example.invalid\", from: \"0.5.1\")\n",
        "Makefile": "AXOLOTY_CONSUMER_VERSION ?= \(makefileVersion)\n",
        "Tests/Support/check-axoloty-semver-consumer.sh": "version=${AXOLOTY_CONSUMER_VERSION:-0.5.1}\n",
        "Tools/AxolotyTooling/AxolotyCommandDispatcher.swift": "private static let version = \"0.5.1\"\n",
        "Tools/AxolotyInspectorCore/InspectorArgumentParser.swift": "public static let version = \"0.5.1\"\n",
        "Tools/AxolotyToolingTests/AxolotyCommandDispatcherTests.swift": "#expect(result.standardOutput == \"axoloty-tool 0.5.1\")\n",
        "Tools/AxolotyToolingTests/AxolotyServeParserTests.swift": "#expect(result.standardOutput == \"ax 0.5.1\")\n",
        "Tools/AxolotyInspectorCoreTests/InspectorArgumentParserTests.swift": "#expect(InspectorArgumentParser.version == \"0.5.1\")\n",
        "docs/API.md": "# Axoloty 0.5.1 API documentation\n",
        "docs/SUPPORT_MATRIX.md": "# Axoloty 0.5.1 support matrix\n",
        "ARCHITECTURE.md": "# Architecture\n- `INV-001` shared production processor (non-waivable)\n- `INV-002` bounded state\n",
        "CONTEXT.md": "# Context\n",
        "docs/ROADMAP.md": "# Roadmap\n",
        "docs/protocol/coaty-core-3.md": "# Profile\n",
        "AGENTS.md": "# Instructions\n## Documentation authority\n## Normal workflow\n## Architectural invariants\n",
        "Embedded/AGENTS.md": "# Instructions\nRoot rules apply to this subtree.\n",
        "Packages/AxolotyWire/AGENTS.md": "# Instructions\nRoot rules apply to this subtree.\n",
        "Tests/AGENTS.md": "# Instructions\nRoot rules apply to this subtree.\n",
        "Tools/AGENTS.md": "# Instructions\nRoot rules apply to this subtree.\n",
        "docs/architecture-exceptions.yml": exception,
    ]
    for (path, content) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    return root
}
