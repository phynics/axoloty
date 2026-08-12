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

    /// Materializes the command without invoking a shell.
    ///
    /// - Parameters:
    ///   - filter: The manifest filter, or an invocation-specific replacement.
    ///   - timeoutSeconds: The manifest deadline for the owning entry.
    /// - Returns: A process-safe ``AxolotyCommandPlan``.
    public func commandPlan(filter: String? = nil, timeoutSeconds: TimeInterval? = nil) -> AxolotyCommandPlan {
        var commandArguments = arguments
        if let filterFlag, let filterValue = filter {
            if let flagIndex = commandArguments.firstIndex(of: filterFlag),
               commandArguments.index(after: flagIndex) < commandArguments.endIndex {
                commandArguments[commandArguments.index(after: flagIndex)] = filterValue
            } else {
                commandArguments.append(contentsOf: [filterFlag, filterValue])
            }
        }
        return AxolotyCommandPlan(
            executable: executable,
            arguments: commandArguments,
            environment: environment,
            executionContext: executionContext,
            timeoutSeconds: timeoutSeconds
        )
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

    /// Materializes this node as an executable check node.
    ///
    /// - Parameter filterOverride: An optional filter replacement passed as a
    ///   single process argument.
    /// - Returns: The executable check node.
    public func checkNode(filterOverride: String? = nil) -> AxolotyCheckNode {
        AxolotyCheckNode(
            name: id,
            dependencies: dependencies,
            command: command.commandPlan(
                filter: filterOverride ?? filter,
                timeoutSeconds: timeoutSeconds
            )
        )
    }
}

/// A canonical test tier and its root nodes.
public struct AxolotyCanonicalTestTier: Codable, Equatable, Sendable {
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
        nodes: [String]
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
    }
}

/// Named roots for a canonical execution plan.
public struct AxolotyCanonicalTestPlanDefinition: Codable, Equatable, Sendable {
    /// Roots for ordinary local execution.
    public let nodes: [String]
    /// Roots for CI execution. Missing means the ordinary roots.
    public let ciNodes: [String]?

    /// Creates a plan definition.
    public init(nodes: [String], ciNodes: [String]? = nil) {
        self.nodes = nodes
        self.ciNodes = ciNodes
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

    /// Creates a command for one caller-provided test filter.
    ///
    /// - Parameter filter: The filter passed as one argv element.
    /// - Returns: A bounded command plan.
    public func commandPlan(filter: String) -> AxolotyCommandPlan {
        command.commandPlan(filter: filter, timeoutSeconds: timeoutSeconds)
    }
}

/// A machine-readable explanation of a canonical plan.
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
    /// Ordered nodes in the command graph.
    public let nodes: [AxolotyCanonicalTestNodeExplanation]

    /// Creates an execution explanation.
    public init(schemaVersion: Int, name: String, ci: Bool, nodes: [AxolotyCanonicalTestNodeExplanation]) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.ci = ci
        self.nodes = nodes
    }
}

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
        }
    }

    /// A localized diagnostic suitable for command-line error reporting.
    public var errorDescription: String? { userFriendlyMessage }
}

/// The versioned, checked-in source of all canonical test execution plans.
///
/// Resolved nodes are consumed by ``AxolotyCheckExecutor`` in dependency order
/// and one node at a time. Consequently, manifest lanes, resources, and
/// process-isolation declarations describe and enforce non-overlap at the
/// graph boundary without requiring a parallel scheduler.
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
            availability: { $0.local }
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
            availability: { ci ? $0.ci : $0.local }
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
        let declaredRoots = ci ? (definition.ciNodes ?? definition.nodes) : definition.nodes
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
        return try resolvedPlan(roots: roots, platform: platform, availability: { ci ? $0.ci : $0.local })
    }

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
        availability: (AxolotyCanonicalTestNode) -> Bool
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
        return try AxolotyCheckPlanner().plan(checkNodes, requested: availableRoots)
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
            nodes: entries
        )
    }
}

/// A self-test ownership entry shared with the Node validator.
public struct AxolotySelfTestContractEntry: Codable, Equatable, Sendable {
    /// Repository-relative self-test path.
    public let path: String
    /// Owning Make target.
    public let makeTarget: String
    /// Owning tier.
    public let tier: String

    /// Creates a self-test contract entry.
    public init(path: String, makeTarget: String, tier: String) {
        self.path = path
        self.makeTarget = makeTarget
        self.tier = tier
    }
}

/// Shared artifact names required by the test contract.
public struct AxolotyArtifactContract: Codable, Equatable, Sendable {
    /// Artifacts required after a failure.
    public let requiredOnFailure: [String]
    /// Broker scenario artifacts.
    public let brokerScenarios: [String]
    /// Interoperability scenario artifacts.
    public let interopScenarios: [String]
    /// Generated-input artifacts.
    public let generatedScenarios: [String]

    /// Creates an artifact contract.
    public init(
        requiredOnFailure: [String],
        brokerScenarios: [String],
        interopScenarios: [String],
        generatedScenarios: [String]
    ) {
        self.requiredOnFailure = requiredOnFailure
        self.brokerScenarios = brokerScenarios
        self.interopScenarios = interopScenarios
        self.generatedScenarios = generatedScenarios
    }
}

/// Shared retry and quarantine policy.
public struct AxolotyFlakePolicy: Codable, Equatable, Sendable {
    /// Automatic retries, which must remain zero.
    public let automaticRetries: Int
    /// Visible diagnostic reruns permitted by the contract.
    public let diagnosticReruns: Int
    /// Required quarantine evidence fields.
    public let quarantineRequires: [String]

    /// Creates a flake policy.
    public init(automaticRetries: Int, diagnosticReruns: Int, quarantineRequires: [String]) {
        self.automaticRetries = automaticRetries
        self.diagnosticReruns = diagnosticReruns
        self.quarantineRequires = quarantineRequires
    }
}
