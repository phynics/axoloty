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

    /// Creates a command plan.
    public init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
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

    /// The repository's non-hardware checks, in their canonical dependency graph.
    public static let canonicalNonHardware = AxolotyCheckPlan(nodes: [
        AxolotyCheckNode(name: "resolve", command: AxolotyCommandPlan(executable: "swift", arguments: ["package", "resolve"])),
        AxolotyCheckNode(name: "build", dependencies: ["resolve"], command: AxolotyCommandPlan(executable: "swift", arguments: ["build"])),
        AxolotyCheckNode(name: "test-ax", dependencies: ["build"], command: AxolotyCommandPlan(executable: "swift", arguments: ["test", "--filter", "AxolotyToolingTests"])),
        AxolotyCheckNode(name: "test", dependencies: ["build"], command: AxolotyCommandPlan(executable: "swift", arguments: ["test"])),
    ])
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
