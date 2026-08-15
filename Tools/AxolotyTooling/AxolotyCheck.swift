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

struct AxolotyExecutionContextDiagnostic: Codable, Equatable, Sendable {
    let code: String
    let executable: String
    let declaredContext: AxolotyCommandPlan.ExecutionContext
    let detectedContext: AxolotyCommandPlan.ExecutionContext
    let message: String
    let remediation: String

    init(
        executable: String,
        declaredContext: AxolotyCommandPlan.ExecutionContext,
        detectedContext: AxolotyCommandPlan.ExecutionContext
    ) {
        self.code = "execution_context_mismatch"
        self.executable = executable
        self.declaredContext = declaredContext
        self.detectedContext = detectedContext
        self.message = "Command requires the \(declaredContext.rawValue) execution context, "
            + "but the current tooling process is in the \(detectedContext.rawValue) context."
        self.remediation = declaredContext == .project
            ? "Run this command through the pinned project container."
            : "Run this command directly on the host or configure the project container's "
                + "executable host-runtime wrapper and Unix socket. This prevents accidental "
                + "wrong-context execution; it does not defend against adversarial environment "
                + "or filesystem spoofing."
    }
}

struct AxolotyExecutionContextValidator: Sendable {
    let environment: [String: String]
    private let platform: AxolotyCheckPlan.Platform

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform
    ) {
        self.environment = environment
        self.platform = platform
    }

    var detectedContext: AxolotyCommandPlan.ExecutionContext {
        if environment["AXOLOTY_DEVCONTAINER"] == "1" || platform == .macOS {
            return .project
        }
        return .host
    }

    private var hasHostRuntimeBridge: Bool {
        guard environment["AXOLOTY_DEVCONTAINER"] == "1",
              environment["AXOLOTY_HOST_RUNTIME_BRIDGE"] == "1",
              let runtime = environment["CONTAINER_RUNTIME"],
              FileManager.default.isExecutableFile(atPath: runtime),
              let dockerHost = environment["DOCKER_HOST"],
              dockerHost.hasPrefix("unix://")
        else { return false }

        let socketPath = String(dockerHost.dropFirst("unix://".count))
        guard socketPath.hasPrefix("/") else { return false }
        let resolvedSocketPath = URL(filePath: socketPath).resolvingSymlinksInPath().path
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedSocketPath)
        return (attributes?[.type] as? FileAttributeType) == .typeSocket
    }

    func validate(_ command: AxolotyCommandPlan) -> AxolotyExecutionContextDiagnostic? {
        let usesBridgedHostContext = command.executionContext == .host && hasHostRuntimeBridge
        guard command.executionContext != detectedContext && !usesBridgedHostContext else { return nil }
        return AxolotyExecutionContextDiagnostic(
            executable: command.executable,
            declaredContext: command.executionContext,
            detectedContext: detectedContext
        )
    }

    func failureResult(validating commands: [AxolotyCommandPlan]) -> AxolotyCheckCommandResult? {
        guard let diagnostic = commands.lazy.compactMap(validate).first else { return nil }
        return AxolotyCheckCommandResult(
            exitCode: 64,
            standardError: diagnosticMessage(diagnostic)
        )
    }

    func diagnosticMessage(_ diagnostic: AxolotyExecutionContextDiagnostic) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(diagnostic)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The captured result of a command execution.
public struct AxolotyCheckCommandResult: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case exitCode
        case standardOutput
        case standardError
        case lifecycle
    }

    /// The process exit status.
    public let exitCode: Int32
    /// Standard output captured from the process.
    public let standardOutput: String
    /// Standard error captured from the process.
    public let standardError: String
    /// Lifecycle diagnostics when the command timed out or was cancelled.
    public let lifecycle: AxolotyCommandLifecycle?

    /// Creates a command result.
    public init(
        exitCode: Int32,
        standardOutput: String = "",
        standardError: String = "",
        lifecycle: AxolotyCommandLifecycle? = nil
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.lifecycle = lifecycle
    }

    /// Decodes a command result while accepting pre-lifecycle result payloads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exitCode = try container.decode(Int32.self, forKey: .exitCode)
        standardOutput = try container.decode(String.self, forKey: .standardOutput)
        standardError = try container.decode(String.self, forKey: .standardError)
        lifecycle = try container.decodeIfPresent(AxolotyCommandLifecycle.self, forKey: .lifecycle)
    }

    /// Encodes the existing result fields and lifecycle diagnostics when present.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exitCode, forKey: .exitCode)
        try container.encode(standardOutput, forKey: .standardOutput)
        try container.encode(standardError, forKey: .standardError)
        try container.encodeIfPresent(lifecycle, forKey: .lifecycle)
    }
}

/// A named, dependency-aware check in a check plan.
public struct AxolotyCheckNode: Codable, Equatable, Sendable {
    /// The stable node identifier.
    public let name: String
    /// Names of prerequisite nodes.
    public let dependencies: [String]
    /// The command associated with this node.
    public let command: AxolotyCommandPlan
    /// The node's current status.
    public let status: AxolotyCheckStatus

    /// Creates a check node.
    public init(
        name: String,
        dependencies: [String] = [],
        command: AxolotyCommandPlan,
        status: AxolotyCheckStatus = .planned
    ) {
        self.name = name
        self.dependencies = dependencies
        self.command = command
        self.status = status
    }
}

/// The result associated with a planned check node.
public struct AxolotyCheckResult: Codable, Equatable, Sendable {
    /// The node identifier.
    public let name: String
    /// The final node status.
    public let status: AxolotyCheckStatus
    /// The command result, when execution occurred.
    public let command: AxolotyCheckCommandResult?

    /// Creates a check result.
    public init(name: String, status: AxolotyCheckStatus, command: AxolotyCheckCommandResult? = nil) {
        self.name = name
        self.status = status
        self.command = command
    }
}

/// A deterministic collection of check nodes in execution order.
public struct AxolotyCheckPlan: Codable, Equatable, Sendable {
    /// The plan schema version.
    public let schemaVersion: Int
    /// Nodes ordered so every prerequisite precedes its dependants.
    public let nodes: [AxolotyCheckNode]

    /// Creates a check plan.
    public init(schemaVersion: Int = 1, nodes: [AxolotyCheckNode]) {
        self.schemaVersion = schemaVersion
        self.nodes = nodes
    }

    /// The canonical broker-free project checks owned by the CLI.
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

    /// The initial offline checks for the current host platform.
    public static let initialOffline = initialOffline(for: currentPlatform)

    /// Creates initial offline checks from the checked-in canonical manifest.
    public static func initialOffline(for platform: Platform) -> AxolotyCheckPlan {
        do {
            return try AxolotyCanonicalTestManifest.loadDefault().plan(named: "offline", platform: platform)
        } catch {
            preconditionFailure("Unable to load canonical offline test plan: \(error)")
        }
    }

    /// Creates the offline fixture-bundle generation and verification plan.
    ///
    /// The fixture bundle is assembled entirely from committed wire captures
    /// (fixtures) and is distinct from fresh wire evidence. It proves bundle
    /// integrity and byte-exact offline reproduction; it is not live evidence
    /// of current release wire behavior.
    public static func releaseSnapshots(
        source: String = "Tests/WireCompatibility/Fixtures",
        destination: String = ".testing/fixture-bundle",
        environment: [String: String] = [:]
    ) -> AxolotyCheckPlan {
        let manifest: AxolotyCanonicalTestManifest
        let plan: AxolotyCheckPlan
        do {
            manifest = try AxolotyCanonicalTestManifest.loadDefault()
            plan = try manifest.plan(named: "fixture-bundle")
        } catch {
            preconditionFailure("Unable to load canonical fixture-bundle plan: \(error)")
        }
        let sourceNodes = plan.nodes.map { node in
            AxolotyCheckNode(
                name: node.name,
                dependencies: node.dependencies,
                command: AxolotyCommandPlan(
                    executable: node.command.executable,
                    arguments: node.command.arguments.map { argument in
                        argument == "${SOURCE}" ? source
                            : argument == "${DESTINATION}" ? destination
                            : argument
                    },
                    environment: node.command.environment.merging(environment) { _, value in value },
                    executionContext: node.command.executionContext,
                    timeoutSeconds: node.command.timeoutSeconds
                )
            )
        }
        let nodes = sourceNodes.map { node in
            if node.name == "fixture-bundle-generate" {
                return AxolotyCheckNode(
                    name: node.name,
                    dependencies: node.dependencies,
                    command: AxolotyCommandPlan(
                        executable: node.command.executable,
                        arguments: ["Tests/Support/fixture-bundle.mjs", "generate", source, destination],
                        environment: node.command.environment,
                        executionContext: node.command.executionContext,
                        timeoutSeconds: node.command.timeoutSeconds
                    )
                )
            }
            if node.name == "fixture-bundle-verify" {
                return AxolotyCheckNode(
                    name: node.name,
                    dependencies: node.dependencies,
                    command: AxolotyCommandPlan(
                        executable: node.command.executable,
                        arguments: ["Tests/Support/fixture-bundle.mjs", "verify", destination],
                        environment: node.command.environment,
                        executionContext: node.command.executionContext,
                        timeoutSeconds: node.command.timeoutSeconds
                    )
                )
            }
            return node
        }
        return AxolotyCheckPlan(schemaVersion: manifest.schemaVersion, nodes: nodes)
    }

    /// Creates the explicit host/container plan for live wire capture.
    public static var wireCapture: AxolotyCheckPlan {
        do {
            let manifest = try AxolotyCanonicalTestManifest.loadDefault()
            return try manifest.plan(named: "wire-live")
        } catch {
            preconditionFailure("Unable to load canonical live wire plan: \(error)")
        }
    }

    /// Creates the release checkpoint validation plan.
    ///
    /// Runs all ordinary offline checks plus binary-size benchmarks and
    /// release snapshot verification. Does not flash or probe hardware.
    public static var checkpoint: AxolotyCheckPlan {
        checkpoint(consumerEnvironment: [:])
    }

    /// Creates the checkpoint plan with release snapshot and external-consumer settings.
    ///
    /// - Parameters:
    ///   - source: The wire fixture source directory.
    ///   - destination: The generated fixture-bundle directory.
    ///   - consumerEnvironment: Settings forwarded to the semantic-version consumer gate.
    public static func checkpoint(
        source: String = "Tests/WireCompatibility/Fixtures",
        destination: String = ".testing/fixture-bundle",
        consumerEnvironment: [String: String]
    ) -> AxolotyCheckPlan {
        let manifest: AxolotyCanonicalTestManifest
        let plan: AxolotyCheckPlan
        do {
            manifest = try AxolotyCanonicalTestManifest.loadDefault()
            plan = try manifest.plan(named: "checkpoint")
        } catch {
            preconditionFailure("Unable to load canonical checkpoint plan: \(error)")
        }
        let nodes = plan.nodes.map { node in
            AxolotyCheckNode(
                name: node.name,
                dependencies: node.dependencies,
                command: AxolotyCommandPlan(
                    executable: node.command.executable,
                    arguments: node.command.arguments.map { argument in
                        argument == "${SOURCE}" ? source
                            : argument == "${DESTINATION}" ? destination
                            : argument
                    },
                    environment: node.command.environment.merging(consumerEnvironment) { _, value in value },
                    executionContext: node.command.executionContext,
                    timeoutSeconds: node.command.timeoutSeconds
                )
            )
        }
        return AxolotyCheckPlan(schemaVersion: manifest.schemaVersion, nodes: nodes)
    }

    /// Creates the release checkpoint hardware validation plan.
    ///
    /// Runs the checkpoint plan, then requires an attached ESP32-C6 device
    /// and runs its smoke test. Fails if no device is present.
    ///
    /// - Parameters:
    ///   - device: The embedded device path.
    ///   - source: The wire fixture source directory.
    ///   - destination: The generated fixture-bundle directory.
    ///   - consumerEnvironment: Settings forwarded to the semantic-version consumer gate.
    public static func checkpointHardware(
        device: String = "/dev/ttyACM0",
        source: String = "Tests/WireCompatibility/Fixtures",
        destination: String = ".testing/fixture-bundle",
        consumerEnvironment: [String: String] = [:]
    ) -> AxolotyCheckPlan {
        let manifest: AxolotyCanonicalTestManifest
        let plan: AxolotyCheckPlan
        do {
            manifest = try AxolotyCanonicalTestManifest.loadDefault()
            plan = try manifest.plan(named: "checkpoint-hardware")
        } catch {
            preconditionFailure("Unable to load canonical hardware checkpoint plan: \(error)")
        }
        let nodes = plan.nodes.map { node in
            AxolotyCheckNode(
                name: node.name,
                dependencies: node.dependencies,
                command: AxolotyCommandPlan(
                    executable: node.command.executable,
                    arguments: node.command.arguments.map { argument in
                        argument == "${SOURCE}" ? source
                            : argument == "${DESTINATION}" ? destination
                            : argument
                    },
                    environment: node.command.environment
                        .merging(consumerEnvironment) { _, value in value }
                        .merging(["EMBEDDED_DEVICE": device]) { _, value in value },
                    executionContext: node.command.executionContext,
                    timeoutSeconds: node.command.timeoutSeconds
                )
            )
        }
        return AxolotyCheckPlan(schemaVersion: manifest.schemaVersion, nodes: nodes)
    }

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

/// A versioned machine-readable manifest for a release checkpoint run.
public struct AxolotyCheckpointManifest: Codable, Equatable, Sendable {
    /// The manifest schema version.
    public let schemaVersion: Int
    /// The release version being validated.
    public let releaseVersion: String
    /// The git commit hash.
    public let gitCommit: String
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
    /// ISO 8601 timestamp of when the checkpoint was generated.
    public let timestamp: String

    /// Creates a checkpoint manifest.
    public init(
        schemaVersion: Int = 1,
        releaseVersion: String,
        gitCommit: String,
        gitClean: Bool,
        gitBranch: String,
        swiftVersion: String,
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform,
        hardwareIncluded: Bool,
        results: [AxolotyCheckResult],
        timestamp: String
    ) {
        self.schemaVersion = schemaVersion
        self.releaseVersion = releaseVersion
        self.gitCommit = gitCommit
        self.gitClean = gitClean
        self.gitBranch = gitBranch
        self.swiftVersion = swiftVersion
        self.platform = platform
        self.hardwareIncluded = hardwareIncluded
        self.results = results
        self.timestamp = timestamp
    }
}
public enum AxolotyCheckPlanningError: Error, Equatable, Sendable {
    /// A dependency name is not present in the supplied nodes.
    case missingDependency(node: String, dependency: String)
    /// The graph contains a dependency cycle.
    case cycle([String])
    /// Two nodes use the same stable name.
    case duplicateNode(String)
}

/// Expands check nodes into a stable topological order.
public struct AxolotyCheckPlanner: Sendable {
    /// Creates a planner.
    public init() {}

    /// Plans the requested nodes and all of their prerequisites.
    ///
    /// Duplicate prerequisites are emitted once. Ties are resolved by the
    /// order in which nodes were supplied, making output reproducible.
    public func plan(_ nodes: [AxolotyCheckNode], requested: [String]? = nil) throws -> AxolotyCheckPlan {
        var byName: [String: AxolotyCheckNode] = [:]
        for node in nodes {
            guard byName[node.name] == nil else { throw AxolotyCheckPlanningError.duplicateNode(node.name) }
            byName[node.name] = node
        }
        let roots = requested ?? nodes.map(\.name)
        var included = Set<String>()
        var visiting = Set<String>()
        var stack: [String] = []
        var ordered: [AxolotyCheckNode] = []

        func visit(_ name: String) throws {
            guard let node = byName[name] else {
                let owner = stack.last ?? name
                throw AxolotyCheckPlanningError.missingDependency(node: owner, dependency: name)
            }
            if included.contains(name) { return }
            if visiting.contains(name) {
                throw AxolotyCheckPlanningError.cycle(stack + [name])
            }
            visiting.insert(name)
            stack.append(name)
            for dependency in node.dependencies { try visit(dependency) }
            _ = stack.popLast()
            visiting.remove(name)
            included.insert(name)
            ordered.append(node)
        }

        for root in roots { try visit(root) }
        return AxolotyCheckPlan(nodes: ordered)
    }
}

/// Runs an ``AxolotyCommandPlan`` and captures its externally visible result.
public protocol AxolotyCheckCommandRunning: Sendable {
    /// Executes a command.
    ///
    /// - Parameter command: The command to execute.
    /// - Returns: Its captured process result.
    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult
}

/// A command runner that also owns node-aware lifecycle diagnostics.
public protocol AxolotyLifecycleCommandRunning: AxolotyCheckCommandRunning {
    /// Executes a command with its owning node and lifecycle stage.
    ///
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - context: The node and stage owning the command.
    /// - Returns: Its captured process result.
    func run(_ command: AxolotyCommandPlan, context: AxolotyCommandRunContext) -> AxolotyCheckCommandResult
}

/// Executes a planned check graph while preserving prerequisite failures.
public struct AxolotyCheckExecutor: Sendable {
    private let commandRunner: any AxolotyCheckCommandRunning
    private let contextValidator: AxolotyExecutionContextValidator
    private let cancellation: AxolotyCommandCancellation?

    /// Creates an executor with the command runner used for every node.
    ///
    /// - Parameter commandRunner: The boundary that starts child commands.
    public init(
        commandRunner: any AxolotyCheckCommandRunning,
        cancellation: AxolotyCommandCancellation? = nil
    ) {
        self.commandRunner = commandRunner
        contextValidator = AxolotyExecutionContextValidator()
        self.cancellation = cancellation
    }

    init(
        commandRunner: any AxolotyCheckCommandRunning,
        contextValidator: AxolotyExecutionContextValidator,
        cancellation: AxolotyCommandCancellation? = nil
    ) {
        self.commandRunner = commandRunner
        self.contextValidator = contextValidator
        self.cancellation = cancellation
    }

    /// Runs a plan in dependency order, serializing every graph node.
    ///
    /// A node whose prerequisite failed or was skipped is skipped without
    /// invoking the runner. Execution continues after independent failures so
    /// the manifest describes every planned check.
    /// Independent nodes are intentionally not run concurrently. This serial
    /// graph boundary is the enforcement for canonical lanes, named resource
    /// ownership, and separate-process or exclusive isolation declarations;
    /// commands may still use their own internal test parallelism.
    ///
    /// - Parameter plan: The plan to execute.
    /// - Returns: Results in the plan's deterministic order.
    public func execute(_ plan: AxolotyCheckPlan) -> [AxolotyCheckResult] {
        let validator = contextValidator
        let diagnostics = plan.nodes.reduce(
            into: [String: AxolotyExecutionContextDiagnostic]()
        ) { diagnostics, node in
            if let diagnostic = validator.validate(node.command) {
                diagnostics[node.name] = diagnostic
            }
        }
        if !diagnostics.isEmpty {
            return plan.nodes.map { node in
                if let diagnostic = diagnostics[node.name] {
                    return AxolotyCheckResult(
                        name: node.name,
                        status: .failed,
                        command: AxolotyCheckCommandResult(
                            exitCode: 64,
                            standardError: validator.diagnosticMessage(diagnostic)
                        )
                    )
                }
                return AxolotyCheckResult(name: node.name, status: .skipped)
            }
        }
        var statuses: [String: AxolotyCheckStatus] = [:]
        var results: [AxolotyCheckResult] = []

        for node in plan.nodes {
            if cancellation?.isCancelled == true {
                statuses[node.name] = .skipped
                results.append(AxolotyCheckResult(name: node.name, status: .skipped))
                continue
            }
            guard node.dependencies.allSatisfy({ statuses[$0] == .passed }) else {
                statuses[node.name] = .skipped
                results.append(AxolotyCheckResult(name: node.name, status: .skipped))
                continue
            }

            let commandResult: AxolotyCheckCommandResult
            if let lifecycleRunner = commandRunner as? any AxolotyLifecycleCommandRunning {
                commandResult = lifecycleRunner.run(
                    node.command,
                    context: AxolotyCommandRunContext(node: node.name, stage: "check")
                )
            } else {
                commandResult = commandRunner.run(node.command)
            }
            let status: AxolotyCheckStatus = commandResult.exitCode == 0 ? .passed : .failed
            statuses[node.name] = status
            results.append(AxolotyCheckResult(name: node.name, status: status, command: commandResult))
        }

        return results
    }
}
