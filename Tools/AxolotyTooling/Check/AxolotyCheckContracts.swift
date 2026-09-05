// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The lifecycle state of a check node.
public enum AxolotyCheckStatus: String, Codable, Equatable, Sendable {
    /// The node has been selected but not run.
    case planned
    /// The node completed successfully.
    case passed
    /// The node ran and failed.
    case failed
    /// The node was not run because a prerequisite failed or was skipped.
    case skipped
    /// The node could not start because the enclosing check plan deadline expired.
    case expired
}

/// A command that a check executor may run later.
public struct AxolotyCommandPlan: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case executable
        case arguments
        case environment
        case executionContext
        case timeoutSeconds
    }

    /// The execution context for a command.
    ///
    /// Context validation prevents accidental execution through the wrong
    /// tooling boundary. It is not a security boundary against adversarial
    /// environment or filesystem spoofing.
    public enum ExecutionContext: String, Codable, Equatable, Sendable {
        /// Run in the pinned project container (default).
        case project
        /// Run directly on the host (used by wire-capture scripts that
        /// need host-level container orchestration).
        case host
    }

    /// The executable name.
    public let executable: String
    /// Arguments passed to the executable.
    public let arguments: [String]
    /// Environment values added for the command.
    public let environment: [String: String]
    /// The command execution boundary.
    public let executionContext: ExecutionContext
    /// An optional per-command timeout in seconds.
    public let timeoutSeconds: TimeInterval?

    /// Creates a command plan.
    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        executionContext: ExecutionContext = .project,
        timeoutSeconds: TimeInterval? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.executionContext = executionContext
        self.timeoutSeconds = timeoutSeconds
    }

    /// Decodes a command plan, treating a missing execution context from
    /// schema-v1 payloads as ``ExecutionContext/project``.
    ///
    /// - Parameter decoder: The decoder supplying the command plan.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        executable = try container.decode(String.self, forKey: .executable)
        arguments = try container.decode([String].self, forKey: .arguments)
        environment = try container.decode([String: String].self, forKey: .environment)
        executionContext = try container.decodeIfPresent(
            ExecutionContext.self,
            forKey: .executionContext
        ) ?? .project
        timeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds)
    }

    /// Encodes a command plan with its execution context explicitly present.
    ///
    /// - Parameter encoder: The encoder receiving the command plan.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(executable, forKey: .executable)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(environment, forKey: .environment)
        try container.encode(executionContext, forKey: .executionContext)
        try container.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
    }
}

/// The captured result of a command execution.
public struct AxolotyCheckCommandResult: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case exitCode
        case standardOutput
        case standardError
        case lifecycle
        case observation
    }

    /// The process exit status.
    public let exitCode: Int32
    /// Standard output captured from the process.
    public let standardOutput: String
    /// Standard error captured from the process.
    public let standardError: String
    /// Lifecycle diagnostics when the command timed out or was cancelled.
    public let lifecycle: AxolotyCommandLifecycle?
    /// Diagnostics observed for a command that reached normal process completion.
    public let observation: AxolotyCommandObservation?

    /// Creates a command result.
    public init(
        exitCode: Int32,
        standardOutput: String = "",
        standardError: String = "",
        lifecycle: AxolotyCommandLifecycle? = nil,
        observation: AxolotyCommandObservation? = nil
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.lifecycle = lifecycle
        self.observation = observation
    }

    /// Decodes a command result while accepting pre-lifecycle result payloads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exitCode = try container.decode(Int32.self, forKey: .exitCode)
        standardOutput = try container.decode(String.self, forKey: .standardOutput)
        standardError = try container.decode(String.self, forKey: .standardError)
        lifecycle = try container.decodeIfPresent(AxolotyCommandLifecycle.self, forKey: .lifecycle)
        observation = try container.decodeIfPresent(AxolotyCommandObservation.self, forKey: .observation)
    }

    /// Encodes the existing result fields and lifecycle diagnostics when present.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exitCode, forKey: .exitCode)
        try container.encode(standardOutput, forKey: .standardOutput)
        try container.encode(standardError, forKey: .standardError)
        try container.encodeIfPresent(lifecycle, forKey: .lifecycle)
        try container.encodeIfPresent(observation, forKey: .observation)
    }
}

/// Diagnostics captured when a subprocess completes without interruption.
public struct AxolotyCommandObservation: Codable, Equatable, Sendable {
    /// Subprocess elapsed wall-clock time in seconds.
    public let elapsedSeconds: TimeInterval
    /// The last Swift test observed in streamed output, when present.
    public let lastTest: String?
    /// Total bytes observed across standard output and standard error.
    public let outputBytes: Int
    /// Directory containing the command artifacts.
    public let artifactPath: String

    /// Creates a successful-lifecycle command observation.
    public init(elapsedSeconds: TimeInterval, lastTest: String?, outputBytes: Int, artifactPath: String) {
        self.elapsedSeconds = elapsedSeconds
        self.lastTest = lastTest
        self.outputBytes = outputBytes
        self.artifactPath = artifactPath
    }
}

/// A named, dependency-aware check in a check plan.
public struct AxolotyCheckNode: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case name
        case dependencies
        case command
        case status
        case resources
        case expectedDurationSeconds
    }

    /// The stable node identifier.
    public let name: String
    /// Names of prerequisite nodes.
    public let dependencies: [String]
    /// The command associated with this node.
    public let command: AxolotyCommandPlan
    /// The node's current status.
    public let status: AxolotyCheckStatus
    /// Named external resources that must be held while this node runs.
    public let resources: [String]
    /// Wall-clock duration after which the executor emits an overrun warning.
    public let expectedDurationSeconds: TimeInterval?

    /// Creates a check node.
    public init(
        name: String,
        dependencies: [String] = [],
        command: AxolotyCommandPlan,
        status: AxolotyCheckStatus = .planned,
        resources: [String] = [],
        expectedDurationSeconds: TimeInterval? = nil
    ) {
        self.name = name
        self.dependencies = dependencies
        self.command = command
        self.status = status
        self.resources = resources
        self.expectedDurationSeconds = expectedDurationSeconds
    }

    /// Decodes a node while accepting manifests written before resource
    /// declarations were added.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        dependencies = try container.decode([String].self, forKey: .dependencies)
        command = try container.decode(AxolotyCommandPlan.self, forKey: .command)
        status = try container.decode(AxolotyCheckStatus.self, forKey: .status)
        resources = try container.decodeIfPresent([String].self, forKey: .resources) ?? []
        expectedDurationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .expectedDurationSeconds)
    }
}

/// Executor-owned timing for a check node.
public struct AxolotyCheckTiming: Codable, Equatable, Sendable {
    /// Total time from node start through completion, including lease acquisition.
    public let elapsedSeconds: TimeInterval
    /// Configured warning threshold, when present.
    public let expectedDurationSeconds: TimeInterval?
    /// Time spent waiting for resource leases.
    public let resourceLeaseWaitSeconds: TimeInterval
    /// Whether elapsed time exceeded the configured expectation.
    public let exceededExpectation: Bool

    /// Creates timing evidence for a completed node.
    public init(
        elapsedSeconds: TimeInterval,
        expectedDurationSeconds: TimeInterval?,
        resourceLeaseWaitSeconds: TimeInterval
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.expectedDurationSeconds = expectedDurationSeconds
        self.resourceLeaseWaitSeconds = resourceLeaseWaitSeconds
        exceededExpectation = expectedDurationSeconds.map { elapsedSeconds >= $0 } ?? false
    }
}

/// The result associated with a planned check node.
public struct AxolotyCheckResult: Codable, Equatable, Sendable {
    /// The node identifier.
    public let name: String
    /// The final node status.
    public let status: AxolotyCheckStatus
    /// The command result, when execution occurred or the executor emitted a
    /// lifecycle diagnostic such as an expired plan deadline.
    public let command: AxolotyCheckCommandResult?
    /// Executor-owned timing, absent for nodes that never started.
    public let timing: AxolotyCheckTiming?

    /// Creates a check result.
    public init(
        name: String,
        status: AxolotyCheckStatus,
        command: AxolotyCheckCommandResult? = nil,
        timing: AxolotyCheckTiming? = nil
    ) {
        self.name = name
        self.status = status
        self.command = command
        self.timing = timing
    }
}

/// A deterministic collection of check nodes in execution order.
public struct AxolotyCheckPlan: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case nodes
        case deadlineSeconds
        case expectedDurationSeconds
    }

    /// The only schema version accepted and emitted by executable check plans.
    public static let currentSchemaVersion = 1

    /// The plan schema version.
    public let schemaVersion: Int
    /// Nodes ordered so every prerequisite precedes its dependants.
    public let nodes: [AxolotyCheckNode]
    /// The absolute wall-clock budget for executing this plan, in seconds.
    ///
    /// The executor starts this budget before the first node and passes the
    /// remaining time to each command. A missing value means that this plan
    /// has no enclosing budget; individual command deadlines still apply.
    public let deadlineSeconds: TimeInterval?
    /// Wall-clock duration after which the executor emits a plan overrun warning.
    public let expectedDurationSeconds: TimeInterval?

    /// Creates a check plan.
    ///
    /// - Parameters:
    ///   - nodes: Dependency-ordered checks to execute.
    ///   - deadlineSeconds: Optional wall-clock budget for the entire plan.
    public init(
        nodes: [AxolotyCheckNode],
        deadlineSeconds: TimeInterval? = nil,
        expectedDurationSeconds: TimeInterval? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.nodes = nodes
        self.deadlineSeconds = deadlineSeconds
        self.expectedDurationSeconds = expectedDurationSeconds
    }

    /// Decodes a schema-versioned executable check plan.
    ///
    /// Schema version 2 belongs to the canonical test manifest and is not a
    /// compatible check-plan representation.
    ///
    /// - Parameter decoder: The decoder supplying the check plan.
    /// - Throws: ``DecodingError`` when the schema version is unsupported or
    ///   the payload does not match the schema-1 check-plan contract.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported AxolotyCheckPlan schema version \(schemaVersion)"
            )
        }
        self.schemaVersion = schemaVersion
        nodes = try container.decode([AxolotyCheckNode].self, forKey: .nodes)
        deadlineSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .deadlineSeconds)
        expectedDurationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .expectedDurationSeconds)
    }

    /// Encodes an executable check plan as schema version 1.
    ///
    /// - Parameter encoder: The encoder receiving the check plan.
    /// - Throws: An encoding error reported by `encoder`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(nodes, forKey: .nodes)
        try container.encodeIfPresent(deadlineSeconds, forKey: .deadlineSeconds)
        try container.encodeIfPresent(expectedDurationSeconds, forKey: .expectedDurationSeconds)
    }

    /// The platform used when selecting platform-specific checks.
    public enum Platform: String, Codable, Equatable, Sendable {
        /// Apple macOS.
        case macOS
        /// Linux.
        case linux
    }

    /// The host platform selected at compile time.
    public static let currentPlatform: Platform = {
        #if os(Linux)
        .linux
        #else
        .macOS
        #endif
    }()

}

/// A versioned machine-readable result from an ``axoloty-tool`` check plan.
public struct AxolotyCheckManifest: Codable, Equatable, Sendable {
    /// The result schema version.
    public let schemaVersion: Int
    /// The platform whose plan was executed.
    public let platform: AxolotyCheckPlan.Platform
    /// Results in deterministic plan order.
    public let results: [AxolotyCheckResult]

    /// Creates a check manifest.
    public init(
        schemaVersion: Int = 1,
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform,
        results: [AxolotyCheckResult]
    ) {
        self.schemaVersion = schemaVersion
        self.platform = platform
        self.results = results
    }
}

/// The disposition of a required release gate in a checkpoint run.
public enum AxolotyCheckpointGateResult: String, Codable, Equatable, Sendable {
    /// The gate's covering nodes ran and passed inside the checkpoint.
    case executed
    /// The gate's covering node(s) ran and at least one failed.
    case failed
    /// The gate was skipped because a covering node did not run.
    case skipped
    /// The gate was covered by externally supplied attestation evidence.
    case attested
}

/// A required release gate and how the checkpoint accounted for it.
public struct AxolotyCheckpointGate: Codable, Equatable, Sendable {
    /// The mandatory release tier identifier.
    public let id: String
    /// How the checkpoint accounted for the gate.
    public let result: AxolotyCheckpointGateResult
    /// Checkpoint node results that cover this gate.
    public let nodes: [AxolotyCheckResult]
    /// The evidence bundle path when the gate was externally evidenced.
    public let evidence: String?
    /// The SHA-256 digest of the validated evidence envelope.
    public let evidenceDigest: String?
    /// A human-readable note explaining the disposition.
    public let note: String?

    /// Creates a release gate disposition.
    public init(
        id: String,
        result: AxolotyCheckpointGateResult,
        nodes: [AxolotyCheckResult] = [],
        evidence: String? = nil,
        evidenceDigest: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.result = result
        self.nodes = nodes
        self.evidence = evidence
        self.evidenceDigest = evidenceDigest
        self.note = note
    }
}

/// A versioned machine-readable manifest for a release checkpoint run.
public struct AxolotyCheckpointManifest: Codable, Equatable, Sendable {
    /// The manifest schema version.
    public let schemaVersion: Int
    /// The release version being validated.
    public let releaseVersion: String
    /// The git commit hash.
    public let gitCommit: String
    /// The git tree hash, when the runner could resolve it.
    public let gitTree: String?
    /// The canonical repository identity used for external evidence.
    public let repository: String?
    /// Whether the working tree was clean.
    public let gitClean: Bool
    /// The git branch name.
    public let gitBranch: String
    /// The Swift compiler version string.
    public let swiftVersion: String
    /// The platform the checkpoint ran on.
    public let platform: AxolotyCheckPlan.Platform
    /// Whether hardware was included.
    public let hardwareIncluded: Bool
    /// Check results in deterministic plan order.
    public let results: [AxolotyCheckResult]
    /// Release gates in deterministic order.
    public let releaseGates: [AxolotyCheckpointGate]
    /// ISO 8601 timestamp of when the checkpoint was generated.
    public let timestamp: String

    /// Creates a checkpoint manifest.
    public init(
        schemaVersion: Int = 3,
        releaseVersion: String,
        gitCommit: String,
        gitTree: String? = nil,
        repository: String? = nil,
        gitClean: Bool,
        gitBranch: String,
        swiftVersion: String,
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform,
        hardwareIncluded: Bool,
        results: [AxolotyCheckResult],
        releaseGates: [AxolotyCheckpointGate],
        timestamp: String
    ) {
        self.schemaVersion = schemaVersion
        self.releaseVersion = releaseVersion
        self.gitCommit = gitCommit
        self.gitTree = gitTree
        self.repository = repository
        self.gitClean = gitClean
        self.gitBranch = gitBranch
        self.swiftVersion = swiftVersion
        self.platform = platform
        self.hardwareIncluded = hardwareIncluded
        self.results = results
        self.releaseGates = releaseGates
        self.timestamp = timestamp
    }
}
