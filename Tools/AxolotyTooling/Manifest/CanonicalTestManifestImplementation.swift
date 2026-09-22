// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Errors produced while loading or resolving the canonical manifest.
public enum AxolotyCanonicalTestManifestError: Error, Equatable, Sendable, LocalizedError {
    /// The checked-in manifest could not be found.
    case notFound([String])
    /// The manifest file could not be read.
    case unreadable(path: String, reason: String)
    /// The manifest file was not valid JSON for the canonical schema.
    case decodingFailure(path: String, reason: String)
    /// A resolved named plan violates a manifest invariant.
    case invalidPlan(name: String, reason: String)
    /// A different schema version was supplied.
    case unsupportedSchema(Int)
    /// A requested tier or plan was not declared.
    case unknownEntry(String)
    /// A requested node is unavailable on the selected platform.
    case unavailableNode(String)
    /// A named plan inherits from a plan that is not declared.
    case missingPlanInheritance(plan: String, parent: String)
    /// Named plan inheritance contains a cycle.
    case planInheritanceCycle([String])

    /// A human-readable explanation suitable for a command diagnostic.
    public var userFriendlyMessage: String {
        switch self {
        case .notFound(let paths):
            return "canonical test manifest not found (checked: \(paths.joined(separator: ", ")))"
        case .unreadable(let path, let reason):
            return "canonical test manifest could not be read at \(path): \(reason)"
        case .decodingFailure(let path, let reason):
            return "canonical test manifest at \(path) is invalid: \(reason)"
        case .invalidPlan(let name, let reason):
            return "canonical test manifest plan \(name) is invalid: \(reason)"
        case .unsupportedSchema(let version):
            return "canonical test manifest schema \(version) is unsupported"
        case .unknownEntry(let name):
            return "canonical test manifest entry not found: \(name)"
        case .unavailableNode(let name):
            return "canonical test node is unavailable on this platform: \(name)"
        case .missingPlanInheritance(let plan, let parent):
            return "canonical test plan \(plan) inherits from unknown plan \(parent)"
        case .planInheritanceCycle(let plans):
            return "canonical test plan inheritance cycle: \(plans.joined(separator: " -> "))"
        }
    }

    /// A localized diagnostic suitable for command-line error reporting.
    public var errorDescription: String? { userFriendlyMessage }
}

/// The versioned, checked-in source of all canonical test execution plans.
public struct AxolotyCanonicalTestManifest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, manifestID, nodes, tiers, requiredGates, testOne
        case selfTests, artifactContract, toolContainerEnv, flakePolicy, quarantine
    }

    /// The current manifest schema version.
    public static let currentSchemaVersion = 2

    /// Manifest schema version.
    public let schemaVersion: Int
    /// Stable manifest identifier.
    public let manifestID: String
    /// All executable canonical nodes.
    public let nodes: [AxolotyCanonicalTestNode]
    /// Tier metadata and roots.
    public let tiers: [AxolotyCanonicalTestTier]
    /// Required, local, CI-available nodes in the `ci` category.
    ///
    /// This projection is derived from ``nodes`` and ``tiers`` so the
    /// serialized manifest cannot carry a second, drifting gate list.
    public var requiredGates: [String] {
        guard let ciTier = tiers.first(where: { $0.id == "ci" }) else { return [] }
        return ciTier.nodes.filter { nodeID in
            guard let node = nodes.first(where: { $0.id == nodeID }) else { return false }
            return node.required && node.local && node.ci
        }
    }

    /// Decodes the manifest while treating the legacy gate array as an
    /// untrusted projection of the declared tiers and nodes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        manifestID = try container.decode(String.self, forKey: .manifestID)
        nodes = try container.decode([AxolotyCanonicalTestNode].self, forKey: .nodes)
        tiers = try container.decode([AxolotyCanonicalTestTier].self, forKey: .tiers)
        _ = try container.decodeIfPresent([String].self, forKey: .requiredGates)
        testOne = try container.decode(AxolotyCanonicalTestInterface.self, forKey: .testOne)
        selfTests = try container.decode([AxolotySelfTestContractEntry].self, forKey: .selfTests)
        artifactContract = try container.decode(AxolotyArtifactContract.self, forKey: .artifactContract)
        toolContainerEnv = try container.decodeIfPresent(AxolotyToolContainerEnv.self, forKey: .toolContainerEnv)
        flakePolicy = try container.decode(AxolotyFlakePolicy.self, forKey: .flakePolicy)
        quarantine = try container.decode([AxolotyQuarantineEntry].self, forKey: .quarantine)
    }

    /// Encodes the derived gate projection under the established manifest key.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(manifestID, forKey: .manifestID)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(tiers, forKey: .tiers)
        try container.encode(requiredGates, forKey: .requiredGates)
        try container.encode(testOne, forKey: .testOne)
        try container.encode(selfTests, forKey: .selfTests)
        try container.encode(artifactContract, forKey: .artifactContract)
        try container.encodeIfPresent(toolContainerEnv, forKey: .toolContainerEnv)
        try container.encode(flakePolicy, forKey: .flakePolicy)
        try container.encode(quarantine, forKey: .quarantine)
    }

    /// The categories a release needs evidence for: every category except
    /// `release` itself, which is their union. Derived so the set cannot drift
    /// from the declared categories.
    public var releaseGates: [String] {
        tiers.map(\.id).filter { $0 != "release" }
    }
    /// Required CI-only gates in addition to ordinary verification.
    /// Mandatory release-tier gates the release checkpoint must account for.
    /// The reusable single-test command interface.
    public let testOne: AxolotyCanonicalTestInterface
    /// Self-test ownership metadata consumed by the Node validator.
    public let selfTests: [AxolotySelfTestContractEntry]
    /// Shared artifact contract.
    public let artifactContract: AxolotyArtifactContract
    /// Container environment allowlists for axoloty-tool release commands.
    public let toolContainerEnv: AxolotyToolContainerEnv?
    /// Shared flake policy.
    public let flakePolicy: AxolotyFlakePolicy
    /// Owned, expiring, evidenced quarantine entries for known-flaky test names.
    public let quarantine: [AxolotyQuarantineEntry]

    /// Creates a canonical manifest data contract.
    public init(
        schemaVersion: Int = AxolotyCanonicalTestManifest.currentSchemaVersion,
        manifestID: String,
        nodes: [AxolotyCanonicalTestNode],
        tiers: [AxolotyCanonicalTestTier],
        testOne: AxolotyCanonicalTestInterface,
        selfTests: [AxolotySelfTestContractEntry],
        artifactContract: AxolotyArtifactContract,
        flakePolicy: AxolotyFlakePolicy,
        quarantine: [AxolotyQuarantineEntry] = [],
        toolContainerEnv: AxolotyToolContainerEnv? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.manifestID = manifestID
        self.nodes = nodes
        self.tiers = tiers
        self.testOne = testOne
        self.selfTests = selfTests
        self.artifactContract = artifactContract
        self.toolContainerEnv = toolContainerEnv
        self.flakePolicy = flakePolicy
        self.quarantine = quarantine
    }
}
