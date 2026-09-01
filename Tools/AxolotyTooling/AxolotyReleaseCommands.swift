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
    case fixtureBundle
    case checkpoint(hardware: Bool)
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

    /// Creates release evidence input.
    init(bundles: [String: ReleaseEvidenceBundle] = [:]) {
        self.bundles = bundles
    }
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
        evidence: ReleaseEvidenceInput
    ) -> CheckpointCertificationResult {
        let hardwareResults = results.filter { result in
            manifest.nodes.first(where: { $0.id == result.name })?.hardware == .required
        }
        let hardwareIncluded = !hardwareResults.isEmpty
            && hardwareResults.allSatisfy { $0.status == .passed }
        let gates = manifest.releaseGates.map { gate in
            disposition(
                gate: gate,
                manifest: manifest,
                results: results,
                metadata: metadata,
                evidence: evidence.bundles[gate]
            )
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
        evidence: ReleaseEvidenceBundle?
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
                    let validated = try validate(
                        envelope: envelope,
                        gate: gate,
                        artifacts: evidence.artifacts,
                        files: evidence.files,
                        metadata: metadata
                    )
                    return AxolotyCheckpointGate(
                        id: gate,
                        result: .attested,
                        nodes: coveringResults,
                        evidence: evidence.path,
                        evidenceDigest: validated,
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

    private func validate(
        envelope data: Data,
        gate: String,
        artifacts: [String: Data],
        files: [String],
        metadata: CheckpointMetadata
    ) throws -> String {
        let envelope: AxolotyEvidenceEnvelope<AxolotyJSONValue>
        do {
            envelope = try JSONDecoder().decode(AxolotyEvidenceEnvelope<AxolotyJSONValue>.self, from: data)
        } catch {
            throw AxolotyReleaseEvidenceError.malformedEnvelope(error.localizedDescription)
        }
        guard envelope.envelopeSchema == AxolotyEvidenceEnvelope<AxolotyJSONValue>.currentSchemaVersion else {
            throw AxolotyReleaseEvidenceError.unsupportedSchema("envelope=\(envelope.envelopeSchema)")
        }
        guard envelope.gate == AxolotyReleaseGateID(rawValue: gate) else {
            throw AxolotyReleaseEvidenceError.gateMismatch(expected: gate, actual: envelope.gate.rawValue)
        }
        guard let commit = try? AxolotyGitCommitSHA(metadata.gitCommit),
              let tree = metadata.gitTree.flatMap({ try? AxolotyGitTreeSHA($0) }),
              let version = try? AxolotySemanticVersion(metadata.releaseVersion),
              let repository = try? AxolotyRepositoryIdentity(metadata.repository ?? "github.com/phynics/axoloty") else {
            throw AxolotyReleaseEvidenceError.invalidSubject("evidence requires full commit/tree and semantic version metadata")
        }
        let subject = AxolotyReleaseSubject(
            repository: repository,
            commit: commit,
            tree: tree,
            version: version,
            clean: metadata.gitClean
        )
        guard envelope.subject == subject else {
            throw AxolotyReleaseEvidenceError.subjectMismatch("repository, commit, tree, version, or clean state differs")
        }
        guard envelope.subject.clean else {
            throw AxolotyReleaseEvidenceError.invalidSubject("release evidence must come from a clean checkout")
        }
        guard envelope.result == .passed else {
            throw AxolotyReleaseEvidenceError.failedEvidence
        }
        try envelope.producer.validate(expectedCommit: envelope.subject.commit)
        guard envelope.gateSchema == 1 else {
            throw AxolotyReleaseEvidenceError.unsupportedSchema(
                "gate=\(envelope.gate.rawValue), schema=\(envelope.gateSchema)"
            )
        }
        guard !envelope.artifacts.isEmpty else {
            throw AxolotyReleaseEvidenceError.artifactMismatch("evidence bundle declares no artifacts")
        }
        var declared = Set<String>()
        for artifact in envelope.artifacts {
            guard (try? AxolotyEvidenceArtifact(
                role: artifact.role,
                relativePath: artifact.relativePath,
                sha256: artifact.sha256,
                byteCount: artifact.byteCount,
                mediaType: artifact.mediaType
            )) != nil else {
                throw AxolotyReleaseEvidenceError.invalidArtifact(artifact.relativePath)
            }
            guard declared.insert(artifact.relativePath).inserted else {
                throw AxolotyReleaseEvidenceError.artifactMismatch(artifact.relativePath)
            }
            guard let value = artifacts[artifact.relativePath],
                  value.count == artifact.byteCount,
                  AxolotySHA256().hash(value) == artifact.sha256 else {
                throw AxolotyReleaseEvidenceError.artifactMismatch(artifact.relativePath)
            }
        }
        for file in files where file != "evidence.json" && !declared.contains(file) {
            throw AxolotyReleaseEvidenceError.artifactMismatch(file)
        }
        return AxolotySHA256().hash(data)
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

    init(
        commandRunner: any AxolotyCheckCommandRunning,
        contextValidator: AxolotyExecutionContextValidator,
        fileSystem: any AxolotyFileSystem,
        environment: [String: String],
        repositoryRoot: URL,
        outputMode: AxolotyCommandOutputMode,
        resolver: Result<AxolotyCanonicalTestPlanResolver, AxolotyCanonicalTestManifestError>,
        executor: AxolotyCheckExecutor,
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
        self.timestampProvider = timestampProvider
    }

    func run(_ command: ReleaseCommand) -> AxolotyCommandResult {
        switch command {
        case .fixtureBundle:
            return fixtureBundle()
        case .checkpoint(let hardware):
            return checkpoint(hardware: hardware)
        }
    }

    private func fixtureBundle() -> AxolotyCommandResult {
        do {
            let source = environment["AXOLOTY_FIXTURE_BUNDLE_SOURCE"] ?? "Tests/AxolotyTests/WireCompatibility/Fixtures"
            let destination = environment["AXOLOTY_FIXTURE_BUNDLE_OUTPUT"] ?? ".testing/fixture-bundle"
            let forwardedEnvironment = [
                "AXOLOTY_IMAGE_IDENTITY", "AXOLOTY_GIT_COMMIT", "AXOLOTY_GIT_CLEAN",
                "AXOLOTY_CONSUMER_REPOSITORY_URL", "AXOLOTY_CONSUMER_VERSION",
                "AXOLOTY_CONSUMER_LOCAL", "AXOLOTY_CONSUMER_LOCAL_VERSION",
            ].reduce(into: [String: String]()) { values, name in values[name] = environment[name] }
            let resolved = try resolver.get()
            let plan = try resolved.resolve(.fixtureBundle(
                source: source,
                destination: destination,
                environment: forwardedEnvironment,
                platform: AxolotyCheckPlan.currentPlatform
            ))
            let results = execute(plan)
            return render(AxolotyCheckManifest(results: results), exitCode: results.allSatisfy { $0.status == .passed } ? 0 : 1)
        } catch {
            return AxolotyCommandResult(standardError: "error: unable to generate fixture bundle\n", exitCode: 70)
        }
    }

    private func checkpoint(hardware: Bool) -> AxolotyCommandResult {
        let source = environment["AXOLOTY_FIXTURE_BUNDLE_SOURCE"] ?? "Tests/AxolotyTests/WireCompatibility/Fixtures"
        let destination = environment["AXOLOTY_FIXTURE_BUNDLE_OUTPUT"] ?? ".testing/fixture-bundle"
        let consumerEnvironment = [
            "AXOLOTY_CONSUMER_REPOSITORY_URL", "AXOLOTY_CONSUMER_VERSION",
            "AXOLOTY_CONSUMER_LOCAL", "AXOLOTY_CONSUMER_LOCAL_VERSION",
        ].reduce(into: [String: String]()) { values, name in values[name] = environment[name] }
        do {
            let resolved = try resolver.get()
            let device = hardware ? (environment["AXOLOTY_DEVICE"] ?? "/dev/ttyACM0") : nil
            let plan = try resolved.resolve(.checkpoint(
                hardwareDevice: device,
                source: source,
                destination: destination,
                consumerEnvironment: consumerEnvironment,
                platform: AxolotyCheckPlan.currentPlatform
            ))
            let gitCommands = metadataCommands()
            if let failure = contextValidator.failureResult(validating: plan.nodes.map(\.command) + gitCommands) {
                return Self.commandResult(failure)
            }
            if let device, !fileSystem.exists(atPath: device) {
                return AxolotyCommandResult(
                    standardError: "error: checkpoint-hardware requires a device at \(device)\n",
                    exitCode: 1
                )
            }
            let results = execute(plan)
            let metadata = collectMetadata(gitCommands: gitCommands)
            let evidence = loadEvidence(for: resolved.manifest)
            let certified = AxolotyCheckpointCertification().certify(
                manifest: resolved.manifest,
                results: results,
                metadata: metadata,
                evidence: evidence
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

    private func loadEvidence(for manifest: AxolotyCanonicalTestManifest) -> ReleaseEvidenceInput {
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
        return ReleaseEvidenceInput(bundles: bundles)
    }

    private func execute(_ plan: AxolotyCheckPlan) -> [AxolotyCheckResult] {
        executor.execute(plan)
    }

    private func render(_ manifest: AxolotyCheckManifest, exitCode: Int32) -> AxolotyCommandResult {
        guard outputMode == .human else { return (try? Self.jsonResult(manifest, exitCode: exitCode)) ?? AxolotyCommandResult(exitCode: 70) }
        return AxolotyCommandResult(standardOutput: humanSummary(manifest.results), exitCode: exitCode)
    }

    private func render(_ manifest: AxolotyCheckpointManifest, exitCode: Int32) -> AxolotyCommandResult {
        guard outputMode == .human else { return (try? Self.jsonResult(manifest, exitCode: exitCode)) ?? AxolotyCommandResult(exitCode: 70) }
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
