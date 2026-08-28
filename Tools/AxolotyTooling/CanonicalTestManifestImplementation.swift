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
///
/// Resolved nodes are consumed by ``AxolotyCheckExecutor`` in dependency order
/// and one node at a time. The enclosing plan deadline is carried into the
/// resolved plan and enforced by the executor. Consequently, manifest lanes,
/// resources, and process-isolation declarations describe and enforce
/// non-overlap at the graph boundary without requiring a parallel scheduler.
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
    public let plans: [String: AxolotyCanonicalTestPlanDefinition]
    /// Required gates that every ordinary verify plan must include.
    public let requiredGates: [String]
    /// Required CI-only gates in addition to ordinary verification.
    public let ciRequiredGates: [String]
    /// Mandatory release-tier gates the release checkpoint must account for.
    public let releaseGates: [String]
    /// The reusable single-test command interface.
    public let testOne: AxolotyCanonicalTestInterface
    /// Self-test ownership metadata consumed by the Node validator.
    public let selfTests: [AxolotySelfTestContractEntry]
    /// Shared artifact contract.
    public let artifactContract: AxolotyArtifactContract
    /// Shared flake policy.
    public let flakePolicy: AxolotyFlakePolicy

    /// Creates a canonical manifest.
    public init(
        schemaVersion: Int = AxolotyCanonicalTestManifest.currentSchemaVersion,
        manifestID: String,
        nodes: [AxolotyCanonicalTestNode],
        tiers: [AxolotyCanonicalTestTier],
        plans: [String: AxolotyCanonicalTestPlanDefinition],
        requiredGates: [String],
        ciRequiredGates: [String],
        releaseGates: [String],
        testOne: AxolotyCanonicalTestInterface,
        selfTests: [AxolotySelfTestContractEntry],
        artifactContract: AxolotyArtifactContract,
        flakePolicy: AxolotyFlakePolicy
    ) {
        self.schemaVersion = schemaVersion
        self.manifestID = manifestID
        self.nodes = nodes
        self.tiers = tiers
        self.plans = plans
        self.requiredGates = requiredGates
        self.ciRequiredGates = ciRequiredGates
        self.releaseGates = releaseGates
        self.testOne = testOne
        self.selfTests = selfTests
        self.artifactContract = artifactContract
        self.flakePolicy = flakePolicy
    }

    /// Loads a manifest from a JSON file.
    ///
    /// - Parameter url: The checked-in manifest URL.
    /// - Returns: A decoded and schema-checked manifest.
    public static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AxolotyCanonicalTestManifestError.notFound([url.path])
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AxolotyCanonicalTestManifestError.unreadable(
                path: url.path,
                reason: error.localizedDescription
            )
        }
        let manifest: Self
        do {
            manifest = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw AxolotyCanonicalTestManifestError.decodingFailure(
                path: url.path,
                reason: error.localizedDescription
            )
        }
        guard manifest.schemaVersion == currentSchemaVersion else {
            throw AxolotyCanonicalTestManifestError.unsupportedSchema(manifest.schemaVersion)
        }
        return manifest
    }

    /// Loads the checked-in project manifest without duplicating its contents
    /// in the executable.
    ///
    /// `AXOLOTY_TEST_MANIFEST` may select an alternate file for validators and
    /// isolated tests. The normal CLI resolves the repository-relative path.
    ///
    /// - Parameter environment: Environment used to select an override path.
    /// - Returns: The canonical project manifest.
    public static func loadDefault(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let sourceRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let currentRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let bundledManifest = Bundle.module.url(forResource: "test-tiers", withExtension: "json")
        let candidates = [
            environment["AXOLOTY_TEST_MANIFEST"].flatMap { path in
                path.isEmpty ? nil : URL(fileURLWithPath: path, relativeTo: currentRoot)
            },
            currentRoot.appending(path: "Tests/Support/test-tiers.json"),
            sourceRoot.appending(path: "Tests/Support/test-tiers.json"),
            bundledManifest,
        ].compactMap { $0 }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return try load(from: candidate)
        }
        throw AxolotyCanonicalTestManifestError.notFound(candidates.map(\.path))
    }

    /// Returns a canonical node by identifier.
    public func node(named id: String) throws -> AxolotyCanonicalTestNode {
        guard let node = nodes.first(where: { $0.id == id }) else {
            throw AxolotyCanonicalTestManifestError.unknownEntry(id)
        }
        return node
    }

    /// Resolves a named tier into a dependency-ordered check plan.
    public func plan(
        tier: String,
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform
    ) throws -> AxolotyCheckPlan {
        guard let definition = tiers.first(where: { $0.id == tier }) else {
            throw AxolotyCanonicalTestManifestError.unknownEntry(tier)
        }
        return try resolvedPlan(
            roots: definition.nodes,
            platform: platform,
            availability: { $0.local },
            deadlineSeconds: definition.timeoutSeconds
        )
    }

    /// Resolves a tier while selecting its CI availability policy.
    public func plan(
        tier: String,
        ci: Bool,
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform
    ) throws -> AxolotyCheckPlan {
        guard let definition = tiers.first(where: { $0.id == tier }) else {
            throw AxolotyCanonicalTestManifestError.unknownEntry(tier)
        }
        return try resolvedPlan(
            roots: definition.nodes,
            platform: platform,
            availability: { ci ? $0.ci : $0.local },
            deadlineSeconds: definition.timeoutSeconds
        )
    }

    /// Resolves a named plan into a dependency-ordered check plan.
    public func plan(
        named name: String,
        ci: Bool = false,
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform
    ) throws -> AxolotyCheckPlan {
        guard let definition = plans[name] else {
            throw AxolotyCanonicalTestManifestError.unknownEntry(name)
        }
        let declaredRoots = try inheritedRoots(
            for: name,
            ci: ci,
            stack: []
        )
        let roots: [String]
        if name == "verify" {
            roots = requiredGates + (ci ? ciRequiredGates : [])
            if !declaredRoots.isEmpty, declaredRoots != roots {
                throw AxolotyCanonicalTestManifestError.invalidPlan(
                    name: name,
                    reason: "verify roots must be derived from requiredGates and ciRequiredGates"
                )
            }
        } else {
            roots = declaredRoots
        }
        if name == "checkpoint-hardware" {
            guard definition.inherits == "checkpoint" else {
                throw AxolotyCanonicalTestManifestError.invalidPlan(
                    name: name,
                    reason: "checkpoint-hardware must inherit checkpoint"
                )
            }
            let ordinary = Set(try inheritedRoots(for: "checkpoint", ci: ci, stack: []))
            let hardware = Set(roots)
            guard ordinary.isSubset(of: hardware), hardware.count > ordinary.count else {
                throw AxolotyCanonicalTestManifestError.invalidPlan(
                    name: name,
                    reason: "checkpoint-hardware must be a strict superset of checkpoint"
                )
            }
        }
        if name == "verify" || name == "offline" {
            for root in roots {
                if let node = nodes.first(where: { $0.id == root }), node.hardware != .forbidden {
                    throw AxolotyCanonicalTestManifestError.invalidPlan(
                        name: name,
                        reason: "hardware node \(root) is forbidden in ordinary/offline plans"
                    )
                }
            }
        }
        return try resolvedPlan(
            roots: roots,
            platform: platform,
            availability: { ci ? $0.ci : $0.local },
            deadlineSeconds: definition.timeoutSeconds
        )
    }

    /// Creates the reusable single-filter command.
    ///
    /// - Parameter filter: The caller's suite or test filter.
    /// - Returns: A bounded command with the filter passed as one argv value.
    public func testOneCommand(filter: String) -> AxolotyCommandPlan {
        testOne.commandPlan(filter: filter)
    }

    private func resolvedPlan(
        roots: [String],
        platform: AxolotyCheckPlan.Platform,
        availability: (AxolotyCanonicalTestNode) -> Bool,
        deadlineSeconds: TimeInterval?
    ) throws -> AxolotyCheckPlan {
        let available = nodes.filter { $0.isAvailable(on: platform) && availability($0) }
        for root in roots {
            guard nodes.contains(where: { $0.id == root }) else {
                throw AxolotyCanonicalTestManifestError.unavailableNode(root)
            }
        }
        let checkNodes = available.map { $0.checkNode() }
        let availableRoots = roots.filter { root in
            guard let node = nodes.first(where: { $0.id == root }) else { return false }
            return node.isAvailable(on: platform) && availability(node)
        }
        return try AxolotyCheckPlanner().plan(
            checkNodes,
            requested: availableRoots,
            deadlineSeconds: deadlineSeconds
        )
    }

    private func inheritedRoots(
        for name: String,
        ci: Bool,
        stack: [String]
    ) throws -> [String] {
        guard let definition = plans[name] else {
            throw AxolotyCanonicalTestManifestError.unknownEntry(name)
        }
        guard !stack.contains(name) else {
            throw AxolotyCanonicalTestManifestError.planInheritanceCycle(stack + [name])
        }
        let localRoots = ci ? (definition.ciNodes ?? definition.nodes) : definition.nodes
        guard let parent = definition.inherits else { return localRoots }
        guard plans[parent] != nil else {
            throw AxolotyCanonicalTestManifestError.missingPlanInheritance(plan: name, parent: parent)
        }
        return try inheritedRoots(for: parent, ci: ci, stack: stack + [name]) + localRoots
    }

}
