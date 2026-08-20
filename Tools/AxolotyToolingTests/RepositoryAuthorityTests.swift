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

@Test
func repositoryAuthorityCountsOnlyInvariantDeclarations() throws {
    let fixture = try makeAuthorityFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let architecture = fixture.appendingPathComponent("ARCHITECTURE.md")
    try """
    # Architecture

    ## Architectural invariants
    - `INV-001` shared production processor (non-waivable)
    - `INV-002` bounded state

    The shared rule is identified by `INV-001` in this explanation and cannot
    be waived.
    """.write(to: architecture, atomically: true, encoding: .utf8)

    let report = AxolotyRepositoryAuthorityValidator(root: fixture).validate()
    #expect(!report.findings.contains { $0.rule == "architecture.invariants" })
}

@Test
func repositoryAuthorityAcceptsFullSemanticVersions() throws {
    let fixture = try makeAuthorityFixture(version: "1.2.3-rc.1+build.7")
    defer { try? FileManager.default.removeItem(at: fixture) }

    let report = AxolotyRepositoryAuthorityValidator(root: fixture).validate()
    #expect(report.status == "passed")
    #expect(report.version == "1.2.3-rc.1+build.7")
}

@Test
func repositoryAuthorityRejectsMalformedExceptionValuesAndMissingTargets() throws {
    let exception = """
    {"schemaVersion":1,"exceptions":[
      {"id":"E-1","invariant":"INV-002","paths":["/absolute.swift"],"reason":" ","ownerIssue":"","owner":7,"compensatingTests":["Tests/Missing.swift"],"introducedDate":"not-a-date","expiry":{"kind":"date","value":"not-a-date"},"removalCondition":""},
      "not-an-object"
    ]}
    """
    let fixture = try makeAuthorityFixture(exception: exception)
    defer { try? FileManager.default.removeItem(at: fixture) }

    let rules = Set(AxolotyRepositoryAuthorityValidator(root: fixture).validate().findings.map(\.rule))
    #expect(rules.isSuperset(of: [
        "exceptions.paths", "exceptions.tests", "exceptions.value", "exceptions.issue",
        "exceptions.introduced-date", "exceptions.expiry", "exceptions.schema",
    ]))
}

@Test
func repositoryAuthorityRejectsWrongLedgerCollectionTypes() throws {
    let fixture = try makeAuthorityFixture(exception: #"{"schemaVersion":1,"exceptions":{}}"#)
    defer { try? FileManager.default.removeItem(at: fixture) }

    let report = AxolotyRepositoryAuthorityValidator(root: fixture).validate()
    #expect(report.findings.contains { $0.rule == "exceptions.schema" })
}

@Test
func repositoryAuthorityChecksDocCVersionArticlesAndMarkdownAnchors() throws {
    let fixture = try makeAuthorityFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    try """
    # Getting Started
    .package(url: "https://example.invalid", from: "0.5.0")
    [Missing heading](../../README.md#does-not-exist)
    <doc:Missing-article>
    """.write(
        to: fixture.appendingPathComponent("Source/Axoloty.docc/GettingStarted.md"),
        atomically: true,
        encoding: .utf8
    )

    let rules = Set(AxolotyRepositoryAuthorityValidator(root: fixture).validate().findings.map(\.rule))
    #expect(rules.contains("version.claim"))
    #expect(rules.contains("links.anchor"))
    #expect(rules.contains("links.docc.resolve"))
}

@Test
func repositoryAuthorityRejectsVolatileRootAndUnscopedAgentGuides() throws {
    let fixture = try makeAuthorityFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let rootAgents = fixture.appendingPathComponent("AGENTS.md")
    try (try String(contentsOf: rootAgents, encoding: .utf8) + "Use /dev/ttyACM0 for release 0.6.0.\n")
        .write(to: rootAgents, atomically: true, encoding: .utf8)
    try "# Tools\nRoot rules apply.\n".write(
        to: fixture.appendingPathComponent("Tools/AGENTS.md"),
        atomically: true,
        encoding: .utf8
    )

    let rules = Set(AxolotyRepositoryAuthorityValidator(root: fixture).validate().findings.map(\.rule))
    #expect(rules.contains("agents.release-number"))
    #expect(rules.contains("agents.volatile"))
    #expect(rules.contains("agents.scoped"))
}

private func makeAuthorityFixture(
    version: String = "0.5.1",
    makefileVersion: String? = nil,
    exception: String = "{\"schemaVersion\":1,\"exceptions\":[]}"
) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-authority-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let files: [String: String] = [
        "VERSION": version + "\n",
        "README.md": "# Axoloty\n.package(url: \"https://example.invalid\", from: \"\(version)\")\n",
        "Source/Axoloty.docc/GettingStarted.md": "# Getting Started\n.package(url: \"https://example.invalid\", from: \"\(version)\")\n",
        "Makefile": "AXOLOTY_CONSUMER_VERSION ?= \(makefileVersion ?? version)\n",
        "Tests/Support/check-axoloty-semver-consumer.sh": "version=${AXOLOTY_CONSUMER_VERSION:-\(version)}\n",
        "Tools/AxolotyTooling/AxolotyCommandDispatcher.swift": "private static let version = \"\(version)\"\n",
        "Tools/AxolotyInspectorCore/InspectorArgumentParser.swift": "public static let version = \"\(version)\"\n",
        "Tools/AxolotyToolingTests/AxolotyCommandDispatcherTests.swift": "#expect(result.standardOutput == \"axoloty-tool \(version)\")\n",
        "Tools/AxolotyToolingTests/AxolotyServeParserTests.swift": "#expect(result.standardOutput == \"ax \(version)\")\n",
        "Tools/AxolotyInspectorCoreTests/InspectorArgumentParserTests.swift": "#expect(InspectorArgumentParser.version == \"\(version)\")\n",
        "docs/API.md": "# Axoloty \(version) API documentation\n",
        "docs/SUPPORT_MATRIX.md": "# Axoloty \(version) support matrix\n",
        "ARCHITECTURE.md": "# Architecture\n- `INV-001` shared production processor (non-waivable)\n- `INV-002` bounded state\n",
        "CONTEXT.md": "# Context\n",
        "docs/ROADMAP.md": "# Roadmap\n",
        "docs/protocol/coaty-core-3.md": "# Profile\n",
        "AGENTS.md": "# Instructions\n## Jurisdiction\n## Documentation authority\n## Architectural invariants\n## Supported workflow\n## Prohibited shortcuts\n## Authority links\n",
        "Embedded/AGENTS.md": "# Instructions\n## Jurisdiction\nThis guide applies to `Embedded/`. The root [`AGENTS.md`](../AGENTS.md) rules apply.\n## Specialized rules\n",
        "Packages/AxolotyWire/AGENTS.md": "# Instructions\n## Jurisdiction\nThis guide applies to `Packages/AxolotyWire/`. The root [`AGENTS.md`](../../AGENTS.md) rules apply.\n## Specialized rules\n",
        "Tests/AGENTS.md": "# Instructions\n## Jurisdiction\nThis guide applies to `Tests/`. The root [`AGENTS.md`](../AGENTS.md) rules apply.\n## Specialized rules\n",
        "Tools/AGENTS.md": "# Instructions\n## Jurisdiction\nThis guide applies to `Tools/`. The root [`AGENTS.md`](../AGENTS.md) rules apply.\n## Specialized rules\n",
        "docs/architecture-exceptions.yml": exception,
    ]
    for (path, content) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    return root
}
