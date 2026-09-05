// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

private let evidenceCommit = try! AxolotyGitCommitSHA(String(repeating: "a", count: 40))
private let evidenceTree = try! AxolotyGitTreeSHA(String(repeating: "b", count: 40))
private let evidenceRepository = try! AxolotyRepositoryIdentity("github.com/phynics/axoloty")
private let evidenceVersion = try! AxolotySemanticVersion("0.5.1")

private func certificationManifest(
    gate: String? = nil,
    hardware: Bool = false
) -> AxolotyCanonicalTestManifest {
    let node = AxolotyCanonicalTestNode(
        id: "checkpoint-node",
        command: AxolotyCanonicalTestCommand(executable: "true"),
        timeoutSeconds: 1,
        expectedDurationSeconds: 1,
        cadence: "release",
        required: true,
        local: true,
        ci: true,
        network: .none,
        broker: .none,
        hardware: hardware ? .required : .forbidden
    )
    let tier = AxolotyCanonicalTestTier(
        id: gate ?? "unused",
        timeoutSeconds: 1,
        expectedDurationSeconds: 1,
        cadence: "release",
        required: true,
        local: true,
        ci: true,
        network: .none,
        broker: .none,
        hardware: hardware ? .required : .forbidden,
        nodes: [node.id]
    )
    return AxolotyCanonicalTestManifest(
        manifestID: "certification-test",
        nodes: [node],
        // releaseGates is derived from the declared categories, so a fixture
        // names its gate by declaring a category with that id.
        tiers: gate == nil ? [] : [tier],
        requiredGates: [],
        testOne: AxolotyCanonicalTestInterface(
            command: AxolotyCanonicalTestCommand(executable: "true"),
            timeoutSeconds: 1,
            expectedDurationSeconds: 1,
            network: .none,
            broker: .none,
            hardware: .forbidden
        ),
        selfTests: [],
        artifactContract: AxolotyArtifactContract(
            requiredOnFailure: [],
            brokerScenarios: [],
            interopScenarios: [],
            generatedScenarios: []
        ),
        flakePolicy: AxolotyFlakePolicy(
            automaticRetries: 0,
            diagnosticReruns: 0,
            quarantineRequires: []
        )
    )
}

private func certificationMetadata(clean: Bool = true) -> CheckpointMetadata {
    CheckpointMetadata(
        releaseVersion: evidenceVersion.description,
        gitCommit: evidenceCommit.description,
        gitTree: evidenceTree.description,
        repository: evidenceRepository.value,
        gitClean: clean,
        gitBranch: "main",
        swiftVersion: "Swift 6",
        timestamp: "2026-09-01T00:00:00Z"
    )
}

private func makeEvidenceBundle(
    gate: AxolotyReleaseGateID = "wire-live",
    artifactContents: Data = Data("capture".utf8),
    subject: AxolotyReleaseSubject? = nil
) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-evidence-\(UUID().uuidString)", isDirectory: true)
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
            commit: evidenceCommit,
            workflow: "release.yml",
            job: "wire-live",
            artifact: "wire-live-evidence"
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
        .appendingPathComponent("axoloty-legacy-evidence-\(UUID().uuidString)", isDirectory: true)
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

@Test
func evidenceLoaderRejectsWrongGateAndSubject() throws {
    let bundle = try makeEvidenceBundle()
    defer { try? FileManager.default.removeItem(at: bundle) }
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
            expectedGate: "g6-non-divergence",
            context: AxolotyEvidenceValidationContext(expectedSubject: subject, bundleRoot: bundle)
        )
        Issue.record("evidence for another gate unexpectedly validated")
    } catch let error as AxolotyReleaseEvidenceError {
        #expect(error == .gateMismatch(expected: "g6-non-divergence", actual: "wire-live"))
    }

    let stale = AxolotyReleaseSubject(
        repository: evidenceRepository,
        commit: evidenceCommit,
        tree: evidenceTree,
        version: try AxolotySemanticVersion("0.6.0"),
        clean: true
    )
    do {
        _ = try AxolotyEvidenceBundleLoader().validate(
            bundle: bundle,
            expectedGate: "wire-live",
            context: AxolotyEvidenceValidationContext(expectedSubject: stale, bundleRoot: bundle)
        )
        Issue.record("stale evidence unexpectedly validated")
    } catch let error as AxolotyReleaseEvidenceError {
        #expect(error == .subjectMismatch("repository, commit, tree, version, or clean state differs"))
    }
}

@Test
func evidenceLoaderRejectsMissingAndUndeclaredArtifacts() throws {
    let bundle = try makeEvidenceBundle()
    let subject = AxolotyReleaseSubject(
        repository: evidenceRepository,
        commit: evidenceCommit,
        tree: evidenceTree,
        version: evidenceVersion,
        clean: true
    )
    try FileManager.default.removeItem(at: bundle.appendingPathComponent("artifacts/capture.jsonl"))
    do {
        _ = try AxolotyEvidenceBundleLoader().validate(
            bundle: bundle,
            expectedGate: "wire-live",
            context: AxolotyEvidenceValidationContext(expectedSubject: subject, bundleRoot: bundle)
        )
        Issue.record("missing artifact unexpectedly validated")
    } catch let error as AxolotyReleaseEvidenceError {
        #expect(error == .artifactMismatch("artifacts/capture.jsonl"))
    }
    try? FileManager.default.removeItem(at: bundle)

    let extraBundle = try makeEvidenceBundle()
    defer { try? FileManager.default.removeItem(at: extraBundle) }
    try Data("undeclared".utf8).write(to: extraBundle.appendingPathComponent("extra.log"))
    do {
        _ = try AxolotyEvidenceBundleLoader().validate(
            bundle: extraBundle,
            expectedGate: "wire-live",
            context: AxolotyEvidenceValidationContext(expectedSubject: subject, bundleRoot: extraBundle)
        )
        Issue.record("undeclared artifact unexpectedly validated")
    } catch let error as AxolotyReleaseEvidenceError {
        #expect(error == .artifactMismatch("extra.log"))
    }
}

@Test
func evidenceLoaderRejectsDirtyAndUnsupportedSchema() throws {
    let dirtySubject = AxolotyReleaseSubject(
        repository: evidenceRepository,
        commit: evidenceCommit,
        tree: evidenceTree,
        version: evidenceVersion,
        clean: false
    )
    let dirty = try makeEvidenceBundle(subject: dirtySubject)
    defer { try? FileManager.default.removeItem(at: dirty) }
    do {
        _ = try AxolotyEvidenceBundleLoader().validate(
            bundle: dirty,
            expectedGate: "wire-live",
            context: AxolotyEvidenceValidationContext(expectedSubject: dirtySubject, bundleRoot: dirty)
        )
        Issue.record("dirty evidence unexpectedly validated")
    } catch let error as AxolotyReleaseEvidenceError {
        #expect(error == .invalidSubject("release evidence must come from a clean checkout"))
    }

    let unsupported = try makeEvidenceBundle()
    defer { try? FileManager.default.removeItem(at: unsupported) }
    let evidenceURL = unsupported.appendingPathComponent("evidence.json")
    guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: evidenceURL)) as? [String: Any] else {
        Issue.record("evidence fixture did not decode as an object")
        return
    }
    object["envelopeSchema"] = 99
    try JSONSerialization.data(withJSONObject: object, options: []).write(to: evidenceURL)
    let subject = AxolotyReleaseSubject(
        repository: evidenceRepository,
        commit: evidenceCommit,
        tree: evidenceTree,
        version: evidenceVersion,
        clean: true
    )
    do {
        _ = try AxolotyEvidenceBundleLoader().validate(
            bundle: unsupported,
            expectedGate: "wire-live",
            context: AxolotyEvidenceValidationContext(expectedSubject: subject, bundleRoot: unsupported)
        )
        Issue.record("unsupported schema unexpectedly validated")
    } catch let error as AxolotyReleaseEvidenceError {
        #expect(error == .unsupportedSchema("envelope=99"))
    }
}

@Test
func evidenceLoaderRejectsImportedProvenanceForAnotherCommit() throws {
    let bundle = try makeEvidenceBundle()
    defer { try? FileManager.default.removeItem(at: bundle) }
    let evidenceURL = bundle.appendingPathComponent("evidence.json")
    guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: evidenceURL)) as? [String: Any],
          var producer = object["producer"] as? [String: Any],
          var provenance = producer["provenance"] as? [String: Any] else {
        Issue.record("evidence fixture did not contain producer provenance")
        return
    }
    provenance["commit"] = String(repeating: "c", count: 40)
    producer["provenance"] = provenance
    object["producer"] = producer
    try JSONSerialization.data(withJSONObject: object, options: []).write(to: evidenceURL)
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
        Issue.record("evidence with stale imported provenance unexpectedly validated")
    } catch let error as AxolotyReleaseEvidenceError {
        #expect(error == .subjectMismatch("producer provenance commit differs"))
    }
}

@Test
func evidenceLoaderRejectsTraversalAndDuplicateArtifacts() throws {
    let subject = AxolotyReleaseSubject(
        repository: evidenceRepository,
        commit: evidenceCommit,
        tree: evidenceTree,
        version: evidenceVersion,
        clean: true
    )

    let traversal = try makeEvidenceBundle()
    defer { try? FileManager.default.removeItem(at: traversal) }
    let traversalURL = traversal.appendingPathComponent("evidence.json")
    guard var traversalObject = try JSONSerialization.jsonObject(
        with: Data(contentsOf: traversalURL)
    ) as? [String: Any],
    var traversalArtifacts = traversalObject["artifacts"] as? [[String: Any]],
    !traversalArtifacts.isEmpty else {
        Issue.record("traversal fixture did not contain artifacts")
        return
    }
    traversalArtifacts[0]["relativePath"] = "../capture.jsonl"
    traversalObject["artifacts"] = traversalArtifacts
    try JSONSerialization.data(withJSONObject: traversalObject).write(to: traversalURL)
    do {
        _ = try AxolotyEvidenceBundleLoader().validate(
            bundle: traversal,
            expectedGate: "wire-live",
            context: AxolotyEvidenceValidationContext(expectedSubject: subject, bundleRoot: traversal)
        )
        Issue.record("traversal artifact unexpectedly validated")
    } catch let error as AxolotyReleaseEvidenceError {
        #expect(error == .invalidArtifact("../capture.jsonl"))
    }

    let duplicate = try makeEvidenceBundle()
    defer { try? FileManager.default.removeItem(at: duplicate) }
    let duplicateURL = duplicate.appendingPathComponent("evidence.json")
    guard var duplicateObject = try JSONSerialization.jsonObject(
        with: Data(contentsOf: duplicateURL)
    ) as? [String: Any],
    var duplicateArtifacts = duplicateObject["artifacts"] as? [[String: Any]],
    let artifact = duplicateArtifacts.first else {
        Issue.record("duplicate fixture did not contain artifacts")
        return
    }
    duplicateArtifacts.append(artifact)
    duplicateObject["artifacts"] = duplicateArtifacts
    try JSONSerialization.data(withJSONObject: duplicateObject).write(to: duplicateURL)
    do {
        _ = try AxolotyEvidenceBundleLoader().validate(
            bundle: duplicate,
            expectedGate: "wire-live",
            context: AxolotyEvidenceValidationContext(expectedSubject: subject, bundleRoot: duplicate)
        )
        Issue.record("duplicate artifact unexpectedly validated")
    } catch let error as AxolotyReleaseEvidenceError {
        #expect(error == .artifactMismatch("artifacts/capture.jsonl"))
    }
}

@Test
func checkpointCertificationHardwareInclusionComesFromExecutedResults() {
    let certifier = AxolotyCheckpointCertification()
    let manifest = certificationManifest(hardware: true)
    let metadata = certificationMetadata()
    let executed = AxolotyCheckResult(name: "checkpoint-node", status: .passed)
    let included = certifier.certify(
        manifest: manifest,
        results: [executed],
        metadata: metadata,
        evidence: ReleaseEvidenceInput()
    )
    let omitted = certifier.certify(
        manifest: manifest,
        results: [],
        metadata: metadata,
        evidence: ReleaseEvidenceInput()
    )

    #expect(included.manifest.hardwareIncluded)
    #expect(included.exitCode == 0)
    #expect(!omitted.manifest.hardwareIncluded)
    #expect(omitted.exitCode == 0)
}

@Test
func checkpointCertificationPreservesBinaryArtifactBytesAndExactSubject() throws {
    let binary = Data([0x00, 0xFF, 0x10, 0x80, 0x0A])
    let bundle = try makeEvidenceBundle(
        artifactContents: binary,
        subject: AxolotyReleaseSubject(
            repository: evidenceRepository,
            commit: evidenceCommit,
            tree: evidenceTree,
            version: evidenceVersion,
            clean: true
        )
    )
    defer { try? FileManager.default.removeItem(at: bundle) }
    let envelope = try Data(contentsOf: bundle.appendingPathComponent("evidence.json"))
    let manifest = certificationManifest(gate: "wire-live")
    let result = AxolotyCheckpointCertification().certify(
        manifest: manifest,
        results: [AxolotyCheckResult(name: "checkpoint-node", status: .passed)],
        metadata: certificationMetadata(),
        evidence: ReleaseEvidenceInput(bundles: [
            "wire-live": ReleaseEvidenceBundle(
                path: bundle.path,
                envelope: envelope,
                artifacts: ["artifacts/capture.jsonl": binary],
                files: ["evidence.json", "artifacts/capture.jsonl"],
                source: .evidenceDirectory
            ),
        ])
    )

    let gate = try #require(result.manifest.releaseGates.first)
    #expect(gate.result == .attested)
    #expect(gate.note == "exact-subject evidence bundle validated")
    #expect(gate.evidenceDigest == AxolotySHA256().hash(envelope))
    #expect(result.exitCode == 0)
}

@Test
func foundationEvidenceByteLoaderPreservesBinaryArtifactBytes() throws {
    let bytes = Data([0x00, 0xFF, 0x10, 0x80, 0x0A])
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-binary-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    try bytes.write(to: url)

    let loader = FoundationFileSystem() as any ReleaseEvidenceByteLoading
    #expect(loader.data(atPath: url.path) == bytes)
    #expect(AxolotySHA256().hash(loader.data(atPath: url.path) ?? Data()) == AxolotySHA256().hash(bytes))
}

@Test
func checkpointCertificationDistinguishesMissingAndUnreadableEvidenceWithEvidencePath() {
    let manifest = certificationManifest(gate: "wire-live")
    let result = AxolotyCheckpointCertification().certify(
        manifest: manifest,
        results: [AxolotyCheckResult(name: "checkpoint-node", status: .passed)],
        metadata: certificationMetadata(),
        evidence: ReleaseEvidenceInput(bundles: [
            "wire-live": ReleaseEvidenceBundle(
                path: "/tmp/missing-bundle",
                envelope: nil,
                source: .explicitPath,
                state: .absent
            ),
        ])
    )

    let gate = result.manifest.releaseGates[0]
    #expect(gate.result == .failed)
    #expect(gate.evidence == "/tmp/missing-bundle")
    #expect(gate.note == "evidence bundle path is missing")
}

@Test
func checkpointCertificationTreatsAbsentEvidenceDirectoryAsNeutralWhenExecuted() {
    let result = AxolotyCheckpointCertification().certify(
        manifest: certificationManifest(gate: "wire-live"),
        results: [AxolotyCheckResult(name: "checkpoint-node", status: .passed)],
        metadata: certificationMetadata(),
        evidence: ReleaseEvidenceInput(bundles: [
            "wire-live": ReleaseEvidenceBundle(
                path: "/tmp/optional-evidence/wire-live",
                envelope: nil,
                source: .evidenceDirectory,
                state: .absent
            ),
        ])
    )

    #expect(result.manifest.releaseGates[0].result == .executed)
    #expect(result.exitCode == 0)
}

@Test
func checkpointCertificationReportsUnreadableEvidenceJsonPath() {
    let path = "/tmp/unreadable-bundle"
    let result = AxolotyCheckpointCertification().certify(
        manifest: certificationManifest(gate: "wire-live"),
        results: [AxolotyCheckResult(name: "checkpoint-node", status: .passed)],
        metadata: certificationMetadata(),
        evidence: ReleaseEvidenceInput(bundles: [
            "wire-live": ReleaseEvidenceBundle(
                path: path,
                envelope: nil,
                source: .evidenceDirectory,
                state: .unreadable(path: path + "/evidence.json")
            ),
        ])
    )

    let gate = result.manifest.releaseGates[0]
    #expect(gate.result == .failed)
    #expect(gate.evidence == path)
    #expect(gate.note == "unable to read evidence bundle: \(path)/evidence.json")
}
