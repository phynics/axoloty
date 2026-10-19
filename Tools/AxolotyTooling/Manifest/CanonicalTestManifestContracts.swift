// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The network boundary declared by a canonical test execution entry.
public enum AxolotyTestNetworkPolicy: String, Codable, Equatable, Sendable {
    /// The command must not use a network.
    case none
    /// The command may use a private test network.
    case isolated
    /// The command owns an isolated broker.
    case isolatedBroker = "isolated-broker"
    /// The command owns isolated containers and their network.
    case isolatedContainers = "isolated-containers"
    /// The command downloads pinned artifacts from the public internet.
    case external
}

/// The broker lifecycle declared by a canonical test execution entry.
public enum AxolotyTestBrokerPolicy: String, Codable, Equatable, Sendable {
    /// No broker is allowed or needed.
    case none
    /// The command starts a private local broker.
    case local
    /// The command uses a broker isolated from other invocations.
    case isolated
}

/// The hardware access declared by a canonical test execution entry.
public enum AxolotyTestHardwarePolicy: String, Codable, Equatable, Sendable {
    /// Hardware probing and reservation are forbidden.
    case forbidden
    /// Hardware may be used when explicitly requested.
    case optional
    /// Hardware is required and absence is a failure.
    case required
}

/// The process and resource isolation declared by a canonical test entry.
public enum AxolotyTestIsolation: String, Codable, Equatable, Sendable {
    /// The command may use ordinary parallelism inside its own process.
    /// This value does not grant graph-level overlap.
    case parallel
    /// The command must be a separate process from other Swift test lanes.
    /// Lane and resource claims control graph-level contention.
    case separateProcess = "separate-process"
    /// The command owns an exclusive resource lane.
    /// Nodes with this isolation are not graph-parallel.
    case exclusive
}

/// The canonical graph scheduling permission for a node.
public enum AxolotyTestConcurrencyPolicy: String, Codable, Equatable, Sendable {
    /// Run alone because the node has not been audited for overlap.
    case serial
    /// The node has been audited to overlap with other eligible nodes.
    case parallel
}

/// A command specification stored in the canonical test manifest.
public struct AxolotyCanonicalTestCommand: Codable, Equatable, Sendable {
    /// The executable passed as `Process.executableURL` or a project command.
    public let executable: String
    /// Arguments passed as individual process arguments.
    public let arguments: [String]
    /// Environment values added to the command.
    public let environment: [String: String]
    /// The execution boundary for the command.
    public let executionContext: AxolotyCommandPlan.ExecutionContext
    /// The option used to append or replace a test filter.
    public let filterFlag: String?

    /// Creates a canonical command specification.
    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        executionContext: AxolotyCommandPlan.ExecutionContext = .project,
        filterFlag: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.executionContext = executionContext
        self.filterFlag = filterFlag
    }

}
/// A typed node in the canonical test execution manifest.
public struct AxolotyCanonicalTestNode: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, dependencies, command, filter, timeoutSeconds, expectedDurationSeconds, cadence
        case required, local, ci, network, broker, hardware, resources, isolation, lane, artifacts
        case platforms, concurrency, sharedResources
    }

    /// The stable node identifier.
    public let id: String
    /// Prerequisite node identifiers.
    public let dependencies: [String]
    /// The process command specification.
    public let command: AxolotyCanonicalTestCommand
    /// The default Swift test filter, when this is a filtered test command.
    public let filter: String?
    /// The hard wall-clock deadline in seconds.
    public let timeoutSeconds: TimeInterval
    /// The expected wall-clock duration in seconds.
    public let expectedDurationSeconds: TimeInterval
    /// The cadence at which this node is intended to run.
    public let cadence: String
    /// Whether the node is a required gate when selected.
    public let required: Bool
    /// Whether local invocations may select the node.
    public let local: Bool
    /// Whether CI invocations may select the node.
    public let ci: Bool
    /// The network boundary.
    public let network: AxolotyTestNetworkPolicy
    /// The broker lifecycle policy.
    public let broker: AxolotyTestBrokerPolicy
    /// The hardware access policy.
    public let hardware: AxolotyTestHardwarePolicy
    /// Named resources owned exclusively by the node while it runs.
    public let resources: [String]
    /// Resources the node reads without modifying. These claims may be shared
    /// by concurrently scheduled nodes; every other resource claim is exclusive.
    public let sharedResources: [String]
    /// The process/resource isolation mode. This does not grant graph-level
    /// overlap; use `concurrency` to declare that permission.
    public let isolation: AxolotyTestIsolation
    /// The explicit scheduling lane, when one is required. Nodes in one lane
    /// do not overlap.
    public let lane: String?
    /// Whether this node has been explicitly audited for graph-level overlap.
    /// Missing values in existing manifests default to serial execution.
    public let concurrency: AxolotyTestConcurrencyPolicy
    /// Artifact names emitted or retained by the node.
    public let artifacts: [String]
    /// Platforms on which the node is available. Missing means all platforms.
    public let platforms: [AxolotyCheckPlan.Platform]?

    /// Creates a canonical test node.
    public init(
        id: String,
        dependencies: [String] = [],
        command: AxolotyCanonicalTestCommand,
        filter: String? = nil,
        timeoutSeconds: TimeInterval,
        expectedDurationSeconds: TimeInterval,
        cadence: String,
        required: Bool,
        local: Bool,
        ci: Bool,
        network: AxolotyTestNetworkPolicy,
        broker: AxolotyTestBrokerPolicy,
        hardware: AxolotyTestHardwarePolicy,
        resources: [String] = [],
        sharedResources: [String] = [],
        isolation: AxolotyTestIsolation = .parallel,
        lane: String? = nil,
        concurrency: AxolotyTestConcurrencyPolicy = .serial,
        artifacts: [String] = [],
        platforms: [AxolotyCheckPlan.Platform]? = nil
    ) {
        self.id = id
        self.dependencies = dependencies
        self.command = command
        self.filter = filter
        self.timeoutSeconds = timeoutSeconds
        self.expectedDurationSeconds = expectedDurationSeconds
        self.cadence = cadence
        self.required = required
        self.local = local
        self.ci = ci
        self.network = network
        self.broker = broker
        self.hardware = hardware
        self.resources = resources
        self.sharedResources = sharedResources
        self.isolation = isolation
        self.lane = lane
        self.concurrency = concurrency
        self.artifacts = artifacts
        self.platforms = platforms
    }

    /// Decodes a canonical node, treating absent scheduling policy as serial.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        dependencies = try container.decode([String].self, forKey: .dependencies)
        command = try container.decode(AxolotyCanonicalTestCommand.self, forKey: .command)
        filter = try container.decodeIfPresent(String.self, forKey: .filter)
        timeoutSeconds = try container.decode(TimeInterval.self, forKey: .timeoutSeconds)
        expectedDurationSeconds = try container.decode(TimeInterval.self, forKey: .expectedDurationSeconds)
        cadence = try container.decode(String.self, forKey: .cadence)
        required = try container.decode(Bool.self, forKey: .required)
        local = try container.decode(Bool.self, forKey: .local)
        ci = try container.decode(Bool.self, forKey: .ci)
        network = try container.decode(AxolotyTestNetworkPolicy.self, forKey: .network)
        broker = try container.decode(AxolotyTestBrokerPolicy.self, forKey: .broker)
        hardware = try container.decode(AxolotyTestHardwarePolicy.self, forKey: .hardware)
        resources = try container.decodeIfPresent([String].self, forKey: .resources) ?? []
        sharedResources = try container.decodeIfPresent([String].self, forKey: .sharedResources) ?? []
        isolation = try container.decodeIfPresent(AxolotyTestIsolation.self, forKey: .isolation) ?? .parallel
        lane = try container.decodeIfPresent(String.self, forKey: .lane)
        concurrency = try container.decodeIfPresent(AxolotyTestConcurrencyPolicy.self, forKey: .concurrency) ?? .serial
        artifacts = try container.decodeIfPresent([String].self, forKey: .artifacts) ?? []
        platforms = try container.decodeIfPresent([AxolotyCheckPlan.Platform].self, forKey: .platforms)
    }

    /// Encodes the canonical node's scheduling and resource policy.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(dependencies, forKey: .dependencies)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(filter, forKey: .filter)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(expectedDurationSeconds, forKey: .expectedDurationSeconds)
        try container.encode(cadence, forKey: .cadence)
        try container.encode(required, forKey: .required)
        try container.encode(local, forKey: .local)
        try container.encode(ci, forKey: .ci)
        try container.encode(network, forKey: .network)
        try container.encode(broker, forKey: .broker)
        try container.encode(hardware, forKey: .hardware)
        try container.encode(resources, forKey: .resources)
        try container.encode(sharedResources, forKey: .sharedResources)
        try container.encode(isolation, forKey: .isolation)
        try container.encodeIfPresent(lane, forKey: .lane)
        try container.encode(concurrency, forKey: .concurrency)
        try container.encode(artifacts, forKey: .artifacts)
        try container.encodeIfPresent(platforms, forKey: .platforms)
    }

    /// Whether the node is available for a platform.
    public func isAvailable(on platform: AxolotyCheckPlan.Platform) -> Bool {
        platforms?.contains(platform) ?? true
    }

}

/// A canonical test tier and its root nodes.
public struct AxolotyCanonicalTestTier: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, timeoutSeconds, expectedDurationSeconds, cadence, required, local, ci
        case makeTarget, workflow, network, broker, hardware, resources, isolation
        case artifacts, nodes
        case attestedFlag = "attested"
    }

    /// The stable tier identifier.
    public let id: String
    /// Tier deadline in seconds.
    public let timeoutSeconds: TimeInterval
    /// Expected tier duration in seconds.
    public let expectedDurationSeconds: TimeInterval
    /// The required execution cadence.
    public let cadence: String
    /// Whether the tier is a required gate.
    public let required: Bool
    /// Whether local execution may select the tier.
    public let local: Bool
    /// Whether CI execution may select the tier.
    public let ci: Bool
    /// The Make target exposing this tier.
    public let makeTarget: String?
    /// The workflow owning this tier, when applicable.
    public let workflow: String?
    /// The network boundary.
    public let network: AxolotyTestNetworkPolicy
    /// The broker lifecycle policy.
    public let broker: AxolotyTestBrokerPolicy
    /// The hardware access policy.
    public let hardware: AxolotyTestHardwarePolicy
    /// Aggregate resource requirements for the tier. Node-level resource claims
    /// control scheduling and shared/exclusive access during execution.
    public let resources: [String]
    /// The process/resource isolation mode declared for the category. Node-level
    /// concurrency permission is declared separately on each executable node.
    public let isolation: AxolotyTestIsolation
    /// Artifact names retained for the tier.
    public let artifacts: [String]
    /// Root node identifiers selected by the tier.
    public let nodes: [String]
    /// Whether the category is proved by recorded evidence rather than run
    /// inside another category. An attested category still runs on its own
    /// (`test-tier TIER=<id>`); it is excluded when a wider category resolves,
    /// because its nodes need a context that category cannot provide.
    public var attested: Bool { attestedFlag ?? false }
    private let attestedFlag: Bool?

    /// Creates a canonical test tier.
    public init(
        id: String,
        timeoutSeconds: TimeInterval,
        expectedDurationSeconds: TimeInterval,
        cadence: String,
        required: Bool,
        local: Bool,
        ci: Bool,
        makeTarget: String? = nil,
        workflow: String? = nil,
        network: AxolotyTestNetworkPolicy,
        broker: AxolotyTestBrokerPolicy,
        hardware: AxolotyTestHardwarePolicy,
        resources: [String] = [],
        isolation: AxolotyTestIsolation = .parallel,
        artifacts: [String] = [],
        nodes: [String],
        attested: Bool = false
    ) {
        self.id = id
        self.timeoutSeconds = timeoutSeconds
        self.expectedDurationSeconds = expectedDurationSeconds
        self.cadence = cadence
        self.required = required
        self.local = local
        self.ci = ci
        self.makeTarget = makeTarget
        self.workflow = workflow
        self.network = network
        self.broker = broker
        self.hardware = hardware
        self.resources = resources
        self.isolation = isolation
        self.artifacts = artifacts
        self.nodes = nodes
        self.attestedFlag = attested
    }
}

/// The reusable command interface for `test-one`.
public struct AxolotyCanonicalTestInterface: Codable, Equatable, Sendable {
    /// The primary command template, bound to the root package.
    public let command: AxolotyCanonicalTestCommand
    /// Additional package-scoped command templates `test-one` may try after the
    /// primary command.
    ///
    /// The root package builds the portable `Packages/*` test targets through
    /// explicit paths, but it does not build `Tools` or `Apps`. Each alternate
    /// carries its own `--package-path` so a filter that only exists in a
    /// separate package still resolves. A `test-one` invocation runs candidates
    /// in order and stops at the first one that runs a test, so a filter the
    /// manifest already places in another package never pays for a root build.
    public let alternates: [AxolotyCanonicalTestCommand]?
    /// Hard deadline in seconds.
    public let timeoutSeconds: TimeInterval
    /// Expected duration in seconds.
    public let expectedDurationSeconds: TimeInterval
    /// The network policy.
    public let network: AxolotyTestNetworkPolicy
    /// The broker policy.
    public let broker: AxolotyTestBrokerPolicy
    /// The hardware policy.
    public let hardware: AxolotyTestHardwarePolicy
    /// Resources needed by the standalone `test-one` invocation.
    public let resources: [String]
    /// The process isolation mode for the command. This is distinct from
    /// graph-level concurrency permission on canonical nodes.
    public let isolation: AxolotyTestIsolation
    /// Artifact names retained by the invocation.
    public let artifacts: [String]

    /// Creates the reusable test-one interface.
    ///
    /// - Parameters:
    ///   - command: The primary root-package command template.
    ///   - alternates: Additional package-scoped command templates.
    ///   - timeoutSeconds: Hard deadline in seconds.
    ///   - expectedDurationSeconds: Expected duration in seconds.
    ///   - network: The network policy.
    ///   - broker: The broker policy.
    ///   - hardware: The hardware policy.
    ///   - resources: Resources owned by the invocation.
    ///   - isolation: The required process isolation mode.
    ///   - artifacts: Artifact names retained by the invocation.
    public init(
        command: AxolotyCanonicalTestCommand,
        alternates: [AxolotyCanonicalTestCommand]? = nil,
        timeoutSeconds: TimeInterval,
        expectedDurationSeconds: TimeInterval,
        network: AxolotyTestNetworkPolicy,
        broker: AxolotyTestBrokerPolicy,
        hardware: AxolotyTestHardwarePolicy,
        resources: [String] = [],
        isolation: AxolotyTestIsolation = .parallel,
        artifacts: [String] = []
    ) {
        self.command = command
        self.alternates = alternates
        self.timeoutSeconds = timeoutSeconds
        self.expectedDurationSeconds = expectedDurationSeconds
        self.network = network
        self.broker = broker
        self.hardware = hardware
        self.resources = resources
        self.isolation = isolation
        self.artifacts = artifacts
    }

}
