// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

// swiftlint:disable file_length cyclomatic_complexity function_body_length

private protocol ReleaseEvidenceFileListing {
    func subpaths(atPath path: String) -> [String]?
}

protocol ReleaseEvidenceByteLoading {
    func data(atPath path: String) -> Data?
}

extension FoundationFileSystem: ReleaseEvidenceFileListing {
    func subpaths(atPath path: String) -> [String]? {
        try? FileManager.default.subpathsOfDirectory(atPath: path).filter { relativePath in
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: URL(filePath: path).appendingPathComponent(relativePath).path
            )
            return (attributes?[.type] as? FileAttributeType) != .typeDirectory
        }
    }
}

extension FoundationFileSystem: ReleaseEvidenceByteLoading {
    func data(atPath path: String) -> Data? { try? Data(contentsOf: URL(filePath: path)) }
}

/// A release-specific command parsed by ``AxolotyCommandParser``.
enum ReleaseCommand: Equatable, Sendable {
    case checkpoint
}

/// Where an externally supplied evidence bundle was requested from.
enum ReleaseEvidenceSource: String, Equatable, Sendable {
    /// Evidence was requested below `AXOLOTY_EVIDENCE_DIR`.
    case evidenceDirectory
    /// Evidence was requested using a gate-specific legacy path.
    case explicitPath
}

/// What release commands observed while loading an evidence bundle.
enum ReleaseEvidenceState: Equatable, Sendable {
    /// No bundle directory was present.
    case absent
    /// The bundle directory was present, but its evidence document was unreadable.
    case unreadable(path: String)
    /// The bundle and evidence document were loaded.
    case loaded
}

/// Metadata captured by a release checkpoint before certification.
struct CheckpointMetadata: Equatable, Sendable {
    /// Release version read from `VERSION`.
    let releaseVersion: String
    /// Full commit identifier resolved for this run.
    let gitCommit: String
    /// Tree identifier resolved for this run, when available.
    let gitTree: String?
    /// Repository identity used by evidence subjects.
    let repository: String?
    /// Whether `git status --porcelain` was empty.
    let gitClean: Bool
    /// Branch resolved for this run.
    let gitBranch: String
    /// Swift version output resolved for this run.
    let swiftVersion: String
    /// Platform on which the checkpoint ran.
    let platform: AxolotyCheckPlan.Platform
    /// ISO 8601 timestamp for the certificate.
    let timestamp: String

    /// Creates checkpoint metadata.
    init(
        releaseVersion: String,
        gitCommit: String,
        gitTree: String? = nil,
        repository: String? = nil,
        gitClean: Bool,
        gitBranch: String,
        swiftVersion: String,
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform,
        timestamp: String
    ) {
        self.releaseVersion = releaseVersion
        self.gitCommit = gitCommit
        self.gitTree = gitTree
        self.repository = repository
        self.gitClean = gitClean
        self.gitBranch = gitBranch
        self.swiftVersion = swiftVersion
        self.platform = platform
        self.timestamp = timestamp
    }
}

/// One in-memory evidence bundle supplied to checkpoint certification.
struct ReleaseEvidenceBundle: Equatable, Sendable {
    /// The path displayed in the resulting checkpoint gate.
    let path: String
    /// The encoded `evidence.json`, when it was readable.
    let envelope: Data?
    /// Bytes for declared artifacts, keyed by bundle-relative path.
    let artifacts: [String: Data]
    /// All files observed in the bundle, excluding directories.
    let files: [String]
    /// The source from which this bundle was requested.
    let source: ReleaseEvidenceSource
    /// The state observed while loading this bundle.
    let state: ReleaseEvidenceState

    /// Creates an in-memory evidence bundle.
    init(
        path: String,
        envelope: Data?,
        artifacts: [String: Data] = [:],
        files: [String] = [],
        source: ReleaseEvidenceSource = .explicitPath,
        state: ReleaseEvidenceState = .loaded
    ) {
        self.path = path
        self.envelope = envelope
        self.artifacts = artifacts
        self.files = files
        self.source = source
        self.state = state
    }
}

/// Evidence loaded by release commands before pure checkpoint certification.
struct ReleaseEvidenceInput: Equatable, Sendable {
    /// Bundles keyed by their release-gate identifier.
    let bundles: [String: ReleaseEvidenceBundle]
    /// SwiftPM's generated dependency inventory, when checkpointed.
    let swiftPMSBOM: SwiftPMSBOMEvidence?

    /// Creates release evidence input.
    init(bundles: [String: ReleaseEvidenceBundle] = [:], swiftPMSBOM: SwiftPMSBOMEvidence? = nil) {
        self.bundles = bundles
        self.swiftPMSBOM = swiftPMSBOM
    }
}

/// The generated root-package SBOM and its validation result.
struct SwiftPMSBOMEvidence: Equatable, Sendable {
    let artifactPath: String
    let digest: String?
    let failure: String?
}

/// The pure result of certifying a checkpoint's in-process evidence.
struct CheckpointCertificationResult: Equatable, Sendable {
    /// The certificate manifest assembled from metadata and results.
    let manifest: AxolotyCheckpointManifest
    /// The process exit status implied by the certificate.
    let exitCode: Int32

}

/// Aggregates canonical results and release evidence without external effects.
struct AxolotyCheckpointCertification: Sendable {
    /// Builds a deterministic certificate and exit status.
    ///
    /// - Parameters:
    ///   - manifest: The one canonical manifest snapshot used for planning.
    ///   - results: Results from the executed checkpoint plan.
    ///   - metadata: Metadata collected by release commands.
    ///   - evidence: Evidence loaded by release commands.
    /// - Returns: The certificate and its process status.
    func certify(
        manifest: AxolotyCanonicalTestManifest,
        results: [AxolotyCheckResult],
        metadata: CheckpointMetadata,
        evidence: ReleaseEvidenceInput,
        expectedProducerID: String? = nil
    ) -> CheckpointCertificationResult {
        let hardwareResults = results.filter { result in
            manifest.nodes.first(where: { $0.id == result.name })?.hardware == .required
        }
        let hardwareIncluded = !hardwareResults.isEmpty
            && hardwareResults.allSatisfy { $0.status == .passed }
        var gates = manifest.releaseGates.map { gate in
            disposition(
                gate: gate,
                manifest: manifest,
                results: results,
                metadata: metadata,
                evidence: evidence.bundles[gate],
                expectedProducerID: expectedProducerID
            )
        }
        if let sbom = evidence.swiftPMSBOM {
            gates.append(AxolotyCheckpointGate(
                id: "swiftpm-sbom",
                result: sbom.failure == nil ? .executed : .failed,
                evidence: sbom.artifactPath,
                evidenceDigest: sbom.digest,
                note: sbom.failure ?? "SwiftPM CycloneDX SBOM matches Package.resolved"
            ))
        }
        let certificate = AxolotyCheckpointManifest(
            releaseVersion: metadata.releaseVersion,
            gitCommit: metadata.gitCommit,
            gitTree: metadata.gitTree,
            repository: metadata.repository,
            gitClean: metadata.gitClean,
            gitBranch: metadata.gitBranch,
            swiftVersion: metadata.swiftVersion,
            platform: metadata.platform,
            hardwareIncluded: hardwareIncluded,
            results: results,
            releaseGates: gates,
            timestamp: metadata.timestamp
        )
        let failedGate = gates.contains { $0.result == .failed || $0.result == .skipped }
        let passed = results.allSatisfy { $0.status == .passed } && !failedGate && metadata.gitClean
        return CheckpointCertificationResult(manifest: certificate, exitCode: passed ? 0 : 1)
    }

    private func disposition(
        gate: String,
        manifest: AxolotyCanonicalTestManifest,
        results: [AxolotyCheckResult],
        metadata: CheckpointMetadata,
        evidence: ReleaseEvidenceBundle?,
        expectedProducerID: String?
    ) -> AxolotyCheckpointGate {
        let resultByName = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0) })
        let coveringNodes = manifest.tiers.first { $0.id == gate }?.nodes ?? []
        let coveringResults = coveringNodes.compactMap { resultByName[$0] }
        if let evidence {
            switch evidence.state {
            case .absent:
                if evidence.source == .explicitPath || coveringResults.isEmpty {
                    return AxolotyCheckpointGate(
                        id: gate,
                        result: .failed,
                        nodes: coveringResults,
                        evidence: evidence.path,
                        note: evidence.source == .explicitPath
                            ? "evidence bundle path is missing"
                            : "required evidence bundle is missing"
                    )
                }
            case .unreadable(let path):
                return AxolotyCheckpointGate(
                    id: gate,
                    result: .failed,
                    nodes: coveringResults,
                    evidence: evidence.path,
                    note: AxolotyReleaseEvidenceError.unreadable(path).localizedDescription
                )
            case .loaded:
                guard let envelope = evidence.envelope else {
                    return AxolotyCheckpointGate(
                        id: gate,
                        result: .failed,
                        nodes: coveringResults,
                        evidence: evidence.path,
                        note: AxolotyReleaseEvidenceError.unreadable(
                            URL(filePath: evidence.path).appendingPathComponent("evidence.json").path
                        ).localizedDescription
                    )
                }
                do {
                    guard let commit = try? AxolotyGitCommitSHA(metadata.gitCommit),
                          let tree = metadata.gitTree.flatMap({ try? AxolotyGitTreeSHA($0) }),
                          let version = try? AxolotySemanticVersion(metadata.releaseVersion),
                          let repository = try? AxolotyRepositoryIdentity(
                              metadata.repository ?? "github.com/phynics/axoloty"
                          ) else {
                        throw AxolotyReleaseEvidenceError.invalidSubject(
                            "evidence requires full commit/tree and semantic version metadata"
                        )
                    }
                    let subject = AxolotyReleaseSubject(
                        repository: repository,
                        commit: commit,
                        tree: tree,
                        version: version,
                        clean: metadata.gitClean
                    )
                    let validated = try AxolotyEvidenceBundleValidator.validate(
                        envelopeData: envelope,
                        expectedGate: AxolotyReleaseGateID(rawValue: gate),
                        context: AxolotyEvidenceValidationContext(
                            expectedSubject: subject,
                            bundleRoot: URL(filePath: evidence.path),
                            expectedProducerID: expectedProducerID
                        ),
                        artifacts: evidence.artifacts,
                        files: evidence.files
                    )
                    return AxolotyCheckpointGate(
                        id: gate,
                        result: .attested,
                        nodes: coveringResults,
                        evidence: evidence.path,
                        evidenceDigest: validated.bundleDigest,
                        note: "exact-subject evidence bundle validated"
                    )
                } catch let error as AxolotyReleaseEvidenceError {
                    return AxolotyCheckpointGate(
                        id: gate,
                        result: .failed,
                        nodes: coveringResults,
                        evidence: evidence.path,
                        note: error.localizedDescription
                    )
                } catch {
                    return AxolotyCheckpointGate(
                        id: gate,
                        result: .failed,
                        nodes: coveringResults,
                        evidence: evidence.path,
                        note: "evidence validation failed: \(error.localizedDescription)"
                    )
                }
            }
        }
        if coveringResults.isEmpty {
            return AxolotyCheckpointGate(
                id: gate,
                result: .skipped,
                nodes: [],
                note: "no covering node ran in the checkpoint and no attestation was supplied"
            )
        }
        if coveringResults.allSatisfy({ $0.status == .passed }) {
            return AxolotyCheckpointGate(id: gate, result: .executed, nodes: coveringResults)
        }
        if coveringResults.contains(where: { $0.status == .failed }) {
            return AxolotyCheckpointGate(id: gate, result: .failed, nodes: coveringResults)
        }
        return AxolotyCheckpointGate(
            id: gate,
            result: .skipped,
            nodes: coveringResults,
            note: "covering node was skipped"
        )
    }

}

/// Executes the fixture and checkpoint release commands.
struct AxolotyReleaseCommands: Sendable {
    private let commandRunner: any AxolotyCheckCommandRunning
    private let contextValidator: AxolotyExecutionContextValidator
    private let fileSystem: any AxolotyFileSystem
    private let environment: [String: String]
    private let repositoryRoot: URL
    private let outputMode: AxolotyCommandOutputMode
    private let resolver: Result<AxolotyCanonicalTestPlanResolver, AxolotyCanonicalTestManifestError>
    private let executor: AxolotyCheckExecutor
    private let timestampProvider: @Sendable () -> String
    private let suppliedSwiftPMSBOM: SwiftPMSBOMEvidence?

    init(
        commandRunner: any AxolotyCheckCommandRunning,
        contextValidator: AxolotyExecutionContextValidator,
        fileSystem: any AxolotyFileSystem,
        environment: [String: String],
        repositoryRoot: URL,
        outputMode: AxolotyCommandOutputMode,
        resolver: Result<AxolotyCanonicalTestPlanResolver, AxolotyCanonicalTestManifestError>,
        executor: AxolotyCheckExecutor,
        suppliedSwiftPMSBOM: SwiftPMSBOMEvidence? = nil,
        timestampProvider: @escaping @Sendable () -> String = {
            ISO8601DateFormatter().string(from: Date())
        }
    ) {
        self.commandRunner = commandRunner
        self.contextValidator = contextValidator
        self.fileSystem = fileSystem
        self.environment = environment
        self.repositoryRoot = repositoryRoot
        self.outputMode = outputMode
        self.resolver = resolver
        self.executor = executor
        self.suppliedSwiftPMSBOM = suppliedSwiftPMSBOM
        self.timestampProvider = timestampProvider
    }

    func run(_ command: ReleaseCommand) -> AxolotyCommandResult {
        switch command {
        case .checkpoint:
            return checkpoint()
        }
    }

    private func checkpoint() -> AxolotyCommandResult {
        let consumerEnvironment = [
            "AXOLOTY_CONSUMER_REPOSITORY_URL", "AXOLOTY_CONSUMER_VERSION",
            "AXOLOTY_CONSUMER_LOCAL", "AXOLOTY_CONSUMER_LOCAL_VERSION",
        ].reduce(into: [String: String]()) { values, name in values[name] = environment[name] }
        do {
            let resolved = try resolver.get()
            let plan = try resolved.resolve(.checkpoint(
                consumerEnvironment: consumerEnvironment,
                platform: AxolotyCheckPlan.currentPlatform
            ))
            let gitCommands = metadataCommands()
            if let failure = contextValidator.failureResult(validating: plan.nodes.map(\.command) + gitCommands) {
                return Self.commandResult(failure)
            }
            let results = execute(plan)
            let metadata = collectMetadata(gitCommands: gitCommands)
            let evidence = loadEvidence(
                for: resolved.manifest,
                swiftPMSBOM: suppliedSwiftPMSBOM ?? generateSwiftPMSBOM()
            )
            let certified = AxolotyCheckpointCertification().certify(
                manifest: resolved.manifest,
                results: results,
                metadata: metadata,
                evidence: evidence,
                expectedProducerID: expectedProducerID
            )
            return render(certified.manifest, exitCode: certified.exitCode)
        } catch let error as AxolotyCanonicalTestManifestError {
            return AxolotyCommandResult(standardError: "error: \(error.userFriendlyMessage)\n", exitCode: 69)
        } catch {
            return AxolotyCommandResult(standardError: "error: \(error.localizedDescription)\n", exitCode: 69)
        }
    }

    private func metadataCommands() -> [AxolotyCommandPlan] {
        let commit = AxolotyCommandPlan(executable: "git", arguments: ["rev-parse", "HEAD"], timeoutSeconds: 60)
        let tree = AxolotyCommandPlan(executable: "git", arguments: ["rev-parse", "HEAD^{tree}"], timeoutSeconds: 60)
        let status = AxolotyCommandPlan(executable: "git", arguments: ["status", "--porcelain"], timeoutSeconds: 60)
        let branch = AxolotyCommandPlan(executable: "git", arguments: ["rev-parse", "--abbrev-ref", "HEAD"], timeoutSeconds: 60)
        let swift = AxolotyCommandPlan(executable: "swift", arguments: ["--version"], timeoutSeconds: 60)
        return (environment["AXOLOTY_GIT_COMMIT"] == nil ? [commit] : [])
            + (environment["AXOLOTY_GIT_TREE"] == nil ? [tree] : [])
            + [status, branch, swift]
    }

    private func collectMetadata(gitCommands: [AxolotyCommandPlan]) -> CheckpointMetadata {
        let values = Dictionary(uniqueKeysWithValues: gitCommands.map { command in
            (command.arguments.joined(separator: " "), commandRunner.run(command).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        let commit = environment["AXOLOTY_GIT_COMMIT"] ?? values["rev-parse HEAD", default: ""]
        let tree = environment["AXOLOTY_GIT_TREE"] ?? values["rev-parse HEAD^{tree}", default: ""]
        let status = values["status --porcelain", default: ""]
        let branch = values["rev-parse --abbrev-ref HEAD", default: ""]
        let swift = values["--version", default: ""]
        let versionPath = repositoryRoot.appendingPathComponent("VERSION").path
        let releaseVersion = fileSystem.contents(atPath: versionPath)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unavailable"
        return CheckpointMetadata(
            releaseVersion: releaseVersion.isEmpty ? "unavailable" : releaseVersion,
            gitCommit: commit,
            gitTree: tree.isEmpty ? nil : tree,
            repository: environment["AXOLOTY_REPOSITORY"] ?? "github.com/phynics/axoloty",
            gitClean: status.isEmpty,
            gitBranch: branch,
            swiftVersion: swift,
            timestamp: timestampProvider()
        )
    }

    /// The producer identity every supplied evidence bundle must declare, when
    /// the operator pins one.
    ///
    /// The value is optional so an unpinned checkpoint keeps accepting any
    /// validated producer. An empty or whitespace-only value is treated as
    /// unpinned rather than as a producer named by the empty string.
    private var expectedProducerID: String? {
        guard let value = environment["AXOLOTY_EVIDENCE_PRODUCER_ID"] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func loadEvidence(
        for manifest: AxolotyCanonicalTestManifest,
        swiftPMSBOM: SwiftPMSBOMEvidence?
    ) -> ReleaseEvidenceInput {
        var bundles: [String: ReleaseEvidenceBundle] = [:]
        for gate in manifest.releaseGates {
            let normalized = gate.uppercased().replacingOccurrences(of: "-", with: "_")
            let legacyKey = "AXOLOTY_ATTESTATION_\(normalized)_PATH"
            let path: String?
            if let root = environment["AXOLOTY_EVIDENCE_DIR"], !root.isEmpty {
                path = URL(fileURLWithPath: root, relativeTo: repositoryRoot).appendingPathComponent(gate).path
            } else if let legacy = environment[legacyKey], !legacy.isEmpty {
                path = legacy
            } else {
                path = nil
            }
            guard let path else { continue }
            let root = URL(fileURLWithPath: path, relativeTo: repositoryRoot).standardizedFileURL
            let evidencePath = root.appendingPathComponent("evidence.json").path
            let source: ReleaseEvidenceSource = environment["AXOLOTY_EVIDENCE_DIR"] == nil
                ? .explicitPath
                : .evidenceDirectory
            guard fileSystem.exists(atPath: path) else {
                bundles[gate] = ReleaseEvidenceBundle(
                    path: path,
                    envelope: nil,
                    source: source,
                    state: .absent
                )
                continue
            }
            let byteLoader = fileSystem as? any ReleaseEvidenceByteLoading
            let envelope = byteLoader?.data(atPath: evidencePath)
            guard let envelope else {
                bundles[gate] = ReleaseEvidenceBundle(
                    path: path,
                    envelope: nil,
                    source: source,
                    state: .unreadable(path: evidencePath)
                )
                continue
            }
            var artifacts: [String: Data] = [:]
            var files: [String] = []
            if let decoded = try? JSONDecoder().decode(
                AxolotyEvidenceEnvelope<AxolotyJSONValue>.self,
                from: envelope
            ) {
                for artifact in decoded.artifacts {
                    let artifactPath = root.appendingPathComponent(artifact.relativePath).path
                    if let value = byteLoader?.data(atPath: artifactPath) {
                        artifacts[artifact.relativePath] = value
                    }
                    files.append(artifact.relativePath)
                }
            }
            if let enumerator = fileSystem as? any ReleaseEvidenceFileListing,
               let discovered = enumerator.subpaths(atPath: root.path) {
                files = discovered
            }
            bundles[gate] = ReleaseEvidenceBundle(
                path: path,
                envelope: envelope,
                artifacts: artifacts,
                files: files,
                source: source,
                state: .loaded
            )
        }
        return ReleaseEvidenceInput(bundles: bundles, swiftPMSBOM: swiftPMSBOM)
    }

    private func generateSwiftPMSBOM() -> SwiftPMSBOMEvidence {
        let relativeDirectory = ".testing/release-evidence/swiftpm-sbom"
        let outputDirectory = repositoryRoot.appendingPathComponent(relativeDirectory, isDirectory: true)
        do {
            if fileSystem.exists(atPath: outputDirectory.path) {
                try FileManager.default.removeItem(at: outputDirectory)
            }
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            return SwiftPMSBOMEvidence(
                artifactPath: relativeDirectory,
                digest: nil,
                failure: "unable to prepare SwiftPM SBOM output: \(error.localizedDescription)"
            )
        }

        let command = AxolotyCommandPlan(
            executable: "swift",
            arguments: [
                "package", "generate-sbom", "--disable-automatic-resolution",
                "--sbom-spec", "cyclonedx", "--sbom-output-dir", relativeDirectory,
            ],
            timeoutSeconds: 300
        )
        let result = commandRunner.run(command)
        guard result.exitCode == 0 else {
            let diagnostic = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = diagnostic.isEmpty ? "exit code \(result.exitCode)" : diagnostic
            return SwiftPMSBOMEvidence(
                artifactPath: relativeDirectory,
                digest: nil,
                failure: "SwiftPM SBOM generation failed: \(reason)"
            )
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            guard files.count == 1 else {
                throw AxolotySwiftPMSBOMError.malformedSBOM
            }
            let sbom = try Data(contentsOf: files[0])
            let lockPath = repositoryRoot.appendingPathComponent("Package.resolved").path
            guard let resolved = (fileSystem as? any ReleaseEvidenceByteLoading)?.data(atPath: lockPath) else {
                throw AxolotyReleaseEvidenceError.unreadable(lockPath)
            }
            try AxolotySwiftPMSBOMValidator().validate(sbom: sbom, resolved: resolved)
            return SwiftPMSBOMEvidence(
                artifactPath: "\(relativeDirectory)/\(files[0].lastPathComponent)",
                digest: AxolotySHA256().hash(sbom),
                failure: nil
            )
        } catch {
            return SwiftPMSBOMEvidence(
                artifactPath: relativeDirectory,
                digest: nil,
                failure: error.localizedDescription
            )
        }
    }

    private func execute(_ plan: AxolotyCheckPlan) -> [AxolotyCheckResult] {
        executor.execute(plan)
    }

    private func render(_ manifest: AxolotyCheckManifest, exitCode: Int32) -> AxolotyCommandResult {
        guard outputMode != .json else { return (try? Self.jsonResult(manifest, exitCode: exitCode)) ?? AxolotyCommandResult(exitCode: 70) }
        return AxolotyCommandResult(standardOutput: humanSummary(manifest.results), exitCode: exitCode)
    }

    private func render(_ manifest: AxolotyCheckpointManifest, exitCode: Int32) -> AxolotyCommandResult {
        guard outputMode != .json else { return (try? Self.jsonResult(manifest, exitCode: exitCode)) ?? AxolotyCommandResult(exitCode: 70) }
        return AxolotyCommandResult(standardOutput: humanSummary(manifest.results), exitCode: exitCode)
    }

    private func humanSummary(_ results: [AxolotyCheckResult]) -> String {
        results.map { "\($0.status.rawValue.uppercased()) \($0.name)" }.joined(separator: "\n") + "\n"
    }

    private static func commandResult(_ result: AxolotyCheckCommandResult) -> AxolotyCommandResult {
        AxolotyCommandResult(standardOutput: result.standardOutput, standardError: result.standardError, exitCode: result.exitCode)
    }

    private static func jsonResult<Value: Encodable>(_ value: Value, exitCode: Int32) throws -> AxolotyCommandResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return AxolotyCommandResult(standardOutput: String(bytes: data, encoding: .utf8) ?? "", exitCode: exitCode)
    }
}

// swiftlint:enable file_length cyclomatic_complexity function_body_length
