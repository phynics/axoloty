// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

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
    public func plan(
        _ nodes: [AxolotyCheckNode],
        requested: [String]? = nil,
        deadlineSeconds: TimeInterval? = nil
    ) throws -> AxolotyCheckPlan {
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
        return AxolotyCheckPlan(nodes: ordered, deadlineSeconds: deadlineSeconds)
    }
}
