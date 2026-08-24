// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

extension AxolotyCheckPlan {
    /// Creates the live wire-capture plan with invocation-scoped artifacts.
    ///
    /// - Parameter environment: Invocation values forwarded to every node.
    /// - Returns: A plan whose wire scripts and manifest verifier share one output directory.
    public static func wireCapture(environment: [String: String]) -> AxolotyCheckPlan {
        do {
            let manifest = try AxolotyCanonicalTestManifest.loadDefault()
            let plan = try manifest.plan(named: "wire-live")
            let outputDirectory = environment["WIRE_OUTPUT_DIR"] ?? ".testing/wire"
            let runID = environment["WIRE_RUN_ID"] ?? environment["AXOLOTY_RUN_ID"]
            var nodes: [AxolotyCheckNode] = []
            nodes.reserveCapacity(plan.nodes.count)
            for node in plan.nodes {
                var nodeEnvironment = node.command.environment
                nodeEnvironment.merge(environment) { _, value in value }
                nodeEnvironment["WIRE_OUTPUT_DIR"] = outputDirectory
                if let runID {
                    nodeEnvironment["WIRE_RUN_ID"] = runID
                }
                let arguments = node.command.arguments.map { argument in
                    switch argument {
                    case ".testing/wire":
                        outputDirectory
                    case ".testing/wire/manifest.json":
                        "\(outputDirectory)/manifest.json"
                    default:
                        argument
                    }
                }
                nodes.append(
                    AxolotyCheckNode(
                        name: node.name,
                        dependencies: node.dependencies,
                        command: AxolotyCommandPlan(
                            executable: node.command.executable,
                            arguments: arguments,
                            environment: nodeEnvironment,
                            executionContext: node.command.executionContext,
                            timeoutSeconds: node.command.timeoutSeconds
                        ),
                        resources: node.resources
                    )
                )
            }
            return AxolotyCheckPlan(
                schemaVersion: plan.schemaVersion,
                nodes: nodes,
                deadlineSeconds: plan.deadlineSeconds
            )
        } catch {
            preconditionFailure("Unable to load canonical live wire plan: \(error)")
        }
    }
}
