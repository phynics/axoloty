// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

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
    /// The executable name.
    public let executable: String
    /// Arguments passed to the executable.
    public let arguments: [String]
    /// Environment values added for the command.
    public let environment: [String: String]

    /// Creates a command plan.
    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// The captured result of a command execution.
public struct AxolotyCheckCommandResult: Codable, Equatable, Sendable {
    /// The process exit status.
    public let exitCode: Int32
    /// Standard output captured from the process.
    public let standardOutput: String
    /// Standard error captured from the process.
    public let standardError: String

    /// Creates a command result.
    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
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
    /// Nodes ordered so every prerequisite precedes its dependants.
    public let nodes: [AxolotyCheckNode]

    /// Creates a check plan.
    public init(nodes: [AxolotyCheckNode]) {
        self.nodes = nodes
    }

    /// The initial broker-free checks migrated to the CLI.
    ///
    /// This intentionally does not claim to replace the repository's complete
    /// non-hardware gate while the remaining test and support tiers still use
    /// their established Makefile entry points.
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

    /// Creates initial offline checks for a selected host platform.
    public static func initialOffline(for platform: Platform) -> AxolotyCheckPlan {
        var nodes: [AxolotyCheckNode] = [
        AxolotyCheckNode(name: "resolve", command: AxolotyCommandPlan(executable: "swift", arguments: ["package", "resolve", "--cache-path", ".swiftpm-cache"])),
        AxolotyCheckNode(name: "build", dependencies: ["resolve"], command: AxolotyCommandPlan(executable: "swift", arguments: ["build", "--cache-path", ".swiftpm-cache", "--disable-automatic-resolution"])),
        AxolotyCheckNode(name: "lint", command: AxolotyCommandPlan(executable: "swiftlint", arguments: ["lint", "--config", ".swiftlint.yml"])),
        AxolotyCheckNode(name: "test-ax", dependencies: ["build"], command: AxolotyCommandPlan(executable: "swift", arguments: ["test", "--cache-path", ".swiftpm-cache", "--disable-automatic-resolution", "--filter", "AxolotyToolingTests"])),
        AxolotyCheckNode(name: "test-wire", dependencies: ["build"], command: AxolotyCommandPlan(executable: "swift", arguments: ["test", "--cache-path", ".swiftpm-cache", "--disable-automatic-resolution", "--filter", "WireFixtureTests|LegacyCaptureFixtureTests|CoatyJs.*CaptureTests|LifecycleCompatibilityScenarioTests|AxolotyIoAssociateTests|AxolotyIoNegativeTests"])),
        ]
        if platform == .linux {
            nodes += [
                AxolotyCheckNode(name: "embedded-build", dependencies: ["build"], command: AxolotyCommandPlan(executable: "Tests/Support/build-embedded-swift.sh")),
                AxolotyCheckNode(name: "embedded-linker", dependencies: ["embedded-build"], command: AxolotyCommandPlan(executable: "Tests/Support/check-embedded-swift-linker.sh")),
            ]
        }
        return AxolotyCheckPlan(nodes: nodes)
    }
}

/// Errors found while expanding a check dependency graph.
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

/// Executes a planned check graph while preserving prerequisite failures.
public struct AxolotyCheckExecutor: Sendable {
    private let commandRunner: any AxolotyCheckCommandRunning

    /// Creates an executor with the command runner used for every node.
    ///
    /// - Parameter commandRunner: The boundary that starts child commands.
    public init(commandRunner: any AxolotyCheckCommandRunning) {
        self.commandRunner = commandRunner
    }

    /// Runs a plan in dependency order.
    ///
    /// A node whose prerequisite failed or was skipped is skipped without
    /// invoking the runner. Execution continues after independent failures so
    /// the manifest describes every planned check.
    ///
    /// - Parameter plan: The plan to execute.
    /// - Returns: Results in the plan's deterministic order.
    public func execute(_ plan: AxolotyCheckPlan) -> [AxolotyCheckResult] {
        var statuses: [String: AxolotyCheckStatus] = [:]
        var results: [AxolotyCheckResult] = []

        for node in plan.nodes {
            guard node.dependencies.allSatisfy({ statuses[$0] == .passed }) else {
                statuses[node.name] = .skipped
                results.append(AxolotyCheckResult(name: node.name, status: .skipped))
                continue
            }

            let commandResult = commandRunner.run(node.command)
            let status: AxolotyCheckStatus = commandResult.exitCode == 0 ? .passed : .failed
            statuses[node.name] = status
            results.append(AxolotyCheckResult(name: node.name, status: status, command: commandResult))
        }

        return results
    }
}
