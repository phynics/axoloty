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
    /// Named plan roots.
    /// Nodes the ci category requires.
    public let requiredGates: [String]

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

    /// Creates a canonical manifest data contract.
    public init(
        schemaVersion: Int = AxolotyCanonicalTestManifest.currentSchemaVersion,
        manifestID: String,
        nodes: [AxolotyCanonicalTestNode],
        tiers: [AxolotyCanonicalTestTier],
        requiredGates: [String],
        testOne: AxolotyCanonicalTestInterface,
        selfTests: [AxolotySelfTestContractEntry],
        artifactContract: AxolotyArtifactContract,
        flakePolicy: AxolotyFlakePolicy,
        toolContainerEnv: AxolotyToolContainerEnv? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.manifestID = manifestID
        self.nodes = nodes
        self.tiers = tiers
        self.requiredGates = requiredGates
        self.testOne = testOne
        self.selfTests = selfTests
        self.artifactContract = artifactContract
        self.toolContainerEnv = toolContainerEnv
        self.flakePolicy = flakePolicy
    }
}
