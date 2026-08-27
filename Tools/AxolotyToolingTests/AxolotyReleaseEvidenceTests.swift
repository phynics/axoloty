// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

private let evidenceCommit = try! AxolotyGitCommitSHA(String(repeating: "a", count: 40))
private let evidenceTree = try! AxolotyGitTreeSHA(String(repeating: "b", count: 40))
private let evidenceRepository = try! AxolotyRepositoryIdentity("github.com/phynics/axoloty")
private let evidenceVersion = try! AxolotySemanticVersion("0.5.1")

private func makeEvidenceBundle(
    gate: AxolotyReleaseGateID = "wire-live",
    artifactContents: Data = Data("capture".utf8),
    subject: AxolotyReleaseSubject? = nil
) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-evidence-(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let artifactURL = root.appendingPathComponent("artifacts/capture.jsonl")
    try FileManager.default.createDirectory(
        at: artifactURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try artifactContents.write(to: artifactURL)
    let artifact = try AxolotyEvidenceArtifact(
        role: "capture",
        relativePath: "artifacts/capture.jsonl",
        sha256: AxolotySHA256().hash(artifactContents),
        byteCount: artifactContents.count,
        mediaType: "application/jsonl"
    )
    let producer = try AxolotyEvidenceProducerIdentity(
        id: "test-producer",
        version: "1",
        disposition: .imported,
        provenance: AxolotyEvidenceProvenance(
            issuer: "github-actions",
            runID: "123",
            commit: evidenceCommit
        )
    )
    let envelope = AxolotyEvidenceEnvelope<AxolotyJSONValue>(
        gate: gate,
        gateSchema: 1,
        subject: subject ?? AxolotyReleaseSubject(
            repository: evidenceRepository,
            commit: evidenceCommit,
            tree: evidenceTree,
            version: evidenceVersion,
            clean: true
        ),
        producer: producer,
        artifacts: [artifact],
        result: .passed,
        payload: .object(["case": .string("complete")])
    )
    try JSONEncoder().encode(envelope).write(to: root.appendingPathComponent("evidence.json"))
    return root
}

@Test
func sha256MatchesKnownVector() {
    #expect(
        AxolotySHA256().hash(Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
}

@Test
func evidenceLoaderValidatesExactSubjectAndArtifactDigest() throws {
    let bundle = try makeEvidenceBundle()
    defer { try? FileManager.default.removeItem(at: bundle) }
    let subject = AxolotyReleaseSubject(
        repository: evidenceRepository,
        commit: evidenceCommit,
        tree: evidenceTree,
        version: evidenceVersion,
        clean: true
    )
    let result = try AxolotyEvidenceBundleLoader().validate(
        bundle: bundle,
        expectedGate: "wire-live",
        context: AxolotyEvidenceValidationContext(expectedSubject: subject, bundleRoot: bundle)
    )
    #expect(result.gate == "wire-live")
    #expect(result.subject == subject)
    #expect(result.bundleDigest.count == 64)
}

@Test
func evidenceLoaderRejectsLegacyStatusOnlyDocument() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-legacy-evidence-(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"schemaVersion":1,"status":"passed"}"#.utf8)
        .write(to: root.appendingPathComponent("evidence.json"))
    let subject = AxolotyReleaseSubject(
        repository: evidenceRepository,
        commit: evidenceCommit,
        tree: evidenceTree,
        version: evidenceVersion,
        clean: true
    )
    do {
        _ = try AxolotyEvidenceBundleLoader().validate(
            bundle: root,
            expectedGate: "wire-live",
            context: AxolotyEvidenceValidationContext(expectedSubject: subject, bundleRoot: root)
        )
        Issue.record("legacy status-only evidence unexpectedly validated")
    } catch let error as AxolotyReleaseEvidenceError {
        #expect(error != .failedEvidence)
    }
}

@Test
func evidenceLoaderRejectsModifiedArtifact() throws {
    let bundle = try makeEvidenceBundle()
    defer { try? FileManager.default.removeItem(at: bundle) }
    try Data("modified".utf8).write(to: bundle.appendingPathComponent("artifacts/capture.jsonl"))
    let subject = AxolotyReleaseSubject(
        repository: evidenceRepository,
        commit: evidenceCommit,
        tree: evidenceTree,
        version: evidenceVersion,
        clean: true
    )
    do {
        _ = try AxolotyEvidenceBundleLoader().validate(
            bundle: bundle,
            expectedGate: "wire-live",
            context: AxolotyEvidenceValidationContext(expectedSubject: subject, bundleRoot: bundle)
        )
        Issue.record("modified evidence artifact unexpectedly validated")
    } catch let error as AxolotyReleaseEvidenceError {
        #expect(error == .artifactMismatch("artifacts/capture.jsonl"))
    }
}
