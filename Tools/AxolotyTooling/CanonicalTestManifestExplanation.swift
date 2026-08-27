// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A machine-readable explanation of a canonical plan node.
public struct AxolotyCanonicalTestNodeExplanation: Codable, Equatable, Sendable {
    /// The node identifier.
    public let id: String
    /// Ordered prerequisite identifiers.
    public let dependencies: [String]
    /// The command executable.
    public let executable: String
    /// The exact argv list.
    public let arguments: [String]
    /// Hard deadline in seconds.
    public let timeoutSeconds: TimeInterval
    /// Expected duration in seconds.
    public let expectedDurationSeconds: TimeInterval
    /// Network, broker, and hardware policies.
    public let network: AxolotyTestNetworkPolicy
    /// Broker lifecycle policy.
    public let broker: AxolotyTestBrokerPolicy
    /// Hardware access policy.
    public let hardware: AxolotyTestHardwarePolicy
    /// Resource ownership names.
    public let resources: [String]
    /// Isolation mode.
    public let isolation: AxolotyTestIsolation
    /// Scheduling lane.
    public let lane: String?
    /// Artifact names.
    public let artifacts: [String]

    /// Creates a node explanation.
    public init(
        id: String,
        dependencies: [String],
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        expectedDurationSeconds: TimeInterval,
        network: AxolotyTestNetworkPolicy,
        broker: AxolotyTestBrokerPolicy,
        hardware: AxolotyTestHardwarePolicy,
        resources: [String],
        isolation: AxolotyTestIsolation,
        lane: String?,
        artifacts: [String]
    ) {
        self.id = id
        self.dependencies = dependencies
        self.executable = executable
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
        self.expectedDurationSeconds = expectedDurationSeconds
        self.network = network
        self.broker = broker
        self.hardware = hardware
        self.resources = resources
        self.isolation = isolation
        self.lane = lane
        self.artifacts = artifacts
    }
}

/// A machine-readable explanation of a canonical tier or plan.
public struct AxolotyCanonicalTestExplanation: Codable, Equatable, Sendable {
    /// Manifest schema version.
    public let schemaVersion: Int
    /// The explained plan or tier label.
    public let name: String
    /// Whether CI roots were selected.
    public let ci: Bool
    /// The absolute wall-clock budget for this plan, in seconds.
    public let timeoutSeconds: TimeInterval?
    /// Ordered nodes in the command graph.
    public let nodes: [AxolotyCanonicalTestNodeExplanation]

    /// Creates an execution explanation.
    public init(
        schemaVersion: Int,
        name: String,
        ci: Bool,
        timeoutSeconds: TimeInterval? = nil,
        nodes: [AxolotyCanonicalTestNodeExplanation]
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.ci = ci
        self.timeoutSeconds = timeoutSeconds
        self.nodes = nodes
    }
}

extension AxolotyCanonicalTestManifest {
    /// Builds an explanation for a named plan.
    public func explanation(
        named name: String,
        ci: Bool = false,
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform
    ) throws -> AxolotyCanonicalTestExplanation {
        let plan = try self.plan(named: name, ci: ci, platform: platform)
        return explanation(for: plan, name: name, ci: ci)
    }

    /// Builds an explanation for a named tier.
    public func explanation(
        tier: String,
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform
    ) throws -> AxolotyCanonicalTestExplanation {
        let plan = try self.plan(tier: tier, platform: platform)
        return explanation(for: plan, name: tier, ci: false)
    }

    /// Builds a CI-aware explanation for a named tier.
    public func explanation(
        tier: String,
        ci: Bool,
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform
    ) throws -> AxolotyCanonicalTestExplanation {
        let plan = try self.plan(tier: tier, ci: ci, platform: platform)
        return explanation(for: plan, name: tier, ci: ci)
    }

    private func explanation(
        for plan: AxolotyCheckPlan,
        name: String,
        ci: Bool
    ) -> AxolotyCanonicalTestExplanation {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let entries = plan.nodes.compactMap { checkNode -> AxolotyCanonicalTestNodeExplanation? in
            guard let node = byID[checkNode.name] else { return nil }
            return AxolotyCanonicalTestNodeExplanation(
                id: node.id,
                dependencies: node.dependencies,
                executable: checkNode.command.executable,
                arguments: checkNode.command.arguments,
                timeoutSeconds: node.timeoutSeconds,
                expectedDurationSeconds: node.expectedDurationSeconds,
                network: node.network,
                broker: node.broker,
                hardware: node.hardware,
                resources: node.resources,
                isolation: node.isolation,
                lane: node.lane,
                artifacts: node.artifacts
            )
        }
        return AxolotyCanonicalTestExplanation(
            schemaVersion: schemaVersion,
            name: name,
            ci: ci,
            timeoutSeconds: plan.deadlineSeconds,
            nodes: entries
        )
    }
}
