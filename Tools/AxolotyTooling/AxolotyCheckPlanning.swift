// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

extension AxolotyCheckPlan {
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
        source: String = "Tests/AxolotyTests/WireCompatibility/Fixtures",
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
                ),
                resources: node.resources
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
                    ),
                    resources: node.resources
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
                    ),
                    resources: node.resources
                )
            }
            return node
        }
        return AxolotyCheckPlan(
            schemaVersion: manifest.schemaVersion,
            nodes: nodes,
            deadlineSeconds: plan.deadlineSeconds
        )
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
        source: String = "Tests/AxolotyTests/WireCompatibility/Fixtures",
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
                ),
                resources: node.resources
            )
        }
        return AxolotyCheckPlan(
            schemaVersion: manifest.schemaVersion,
            nodes: nodes,
            deadlineSeconds: plan.deadlineSeconds
        )
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
        source: String = "Tests/AxolotyTests/WireCompatibility/Fixtures",
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
                ),
                resources: node.resources
            )
        }
        return AxolotyCheckPlan(
            schemaVersion: manifest.schemaVersion,
            nodes: nodes,
            deadlineSeconds: plan.deadlineSeconds
        )
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
