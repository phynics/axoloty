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
    ///
    /// The canonical graph executor still invokes graph nodes serially.
    case parallel
    /// The command must be a separate process from other Swift test lanes.
    ///
    /// The canonical graph executor prevents overlap with other graph nodes.
    case separateProcess = "separate-process"
    /// The command owns an exclusive resource lane.
    ///
    /// The canonical graph executor prevents overlap with other graph nodes.
    case exclusive
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
    /// Named resources owned by the node. Resource ownership is enforced by
    /// the serial canonical graph executor, rather than by a parallel
    /// scheduler.
    public let resources: [String]
    /// The process/resource isolation mode. Graph nodes never overlap; this
    /// value describes the command's permitted internal parallelism and
    /// process boundary.
    public let isolation: AxolotyTestIsolation
    /// The explicit scheduling lane, when one is required. Lanes are
    /// serialized by the canonical graph executor.
    public let lane: String?
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
        isolation: AxolotyTestIsolation = .parallel,
        lane: String? = nil,
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
        self.isolation = isolation
        self.lane = lane
        self.artifacts = artifacts
        self.platforms = platforms
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
    /// Named resources owned by the tier. The serial canonical graph executor
    /// prevents overlapping graph nodes from sharing these resources.
    public let resources: [String]
    /// The process/resource isolation mode at the graph boundary. Nodes are
    /// serialized; this value describes their internal process/test policy.
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

/// Named roots for a canonical execution plan.
public struct AxolotyCanonicalTestPlanDefinition: Codable, Equatable, Sendable {
    /// Roots for ordinary local execution.
    public let nodes: [String]
    /// An optional plan whose roots are included before these roots.
    public let inherits: String?
    /// Roots for CI execution. Missing means the ordinary roots.
    public let ciNodes: [String]?
    /// The absolute wall-clock budget for this plan, in seconds.
    public let timeoutSeconds: TimeInterval?
    /// Expected plan duration used as a warning threshold.
    public let expectedDurationSeconds: TimeInterval?

    /// Creates a plan definition.
    public init(
        nodes: [String],
        inherits: String? = nil,
        ciNodes: [String]? = nil,
        timeoutSeconds: TimeInterval? = nil,
        expectedDurationSeconds: TimeInterval? = nil
    ) {
        self.nodes = nodes
        self.inherits = inherits
        self.ciNodes = ciNodes
        self.timeoutSeconds = timeoutSeconds
        self.expectedDurationSeconds = expectedDurationSeconds
    }
}

/// The reusable command interface for `test-one`.
public struct AxolotyCanonicalTestInterface: Codable, Equatable, Sendable {
    /// The command template.
    public let command: AxolotyCanonicalTestCommand
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
    /// Resources owned by the invocation. A canonical graph invocation is
    /// serialized with other graph nodes.
    public let resources: [String]
    /// The required process isolation mode. The graph executor runs one node
    /// at a time, while the command may control its own test parallelism.
    public let isolation: AxolotyTestIsolation
    /// Artifact names retained by the invocation.
    public let artifacts: [String]

    /// Creates the reusable test-one interface.
    public init(
        command: AxolotyCanonicalTestCommand,
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
