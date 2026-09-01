// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Shared result formatting used by command-family implementations.
enum AxolotyCommandFamilySupport {
    static func jsonResult<Value: Encodable>(
        _ value: Value,
        exitCode: Int32 = 0
    ) throws -> AxolotyCommandResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return AxolotyCommandResult(
            standardOutput: String(bytes: data, encoding: .utf8) ?? "",
            exitCode: exitCode
        )
    }

    static func manifestResult(
        _ manifest: AxolotyCheckManifest,
        outputMode: AxolotyCommandOutputMode,
        exitCode: Int32
    ) -> AxolotyCommandResult {
        guard outputMode == .human else {
            return (try? jsonResult(manifest, exitCode: exitCode))
                ?? AxolotyCommandResult(exitCode: 70)
        }
        return AxolotyCommandResult(
            standardOutput: humanSummary(manifest.results),
            exitCode: exitCode
        )
    }

    static func humanSummary(_ results: [AxolotyCheckResult]) -> String {
        results.map { "\($0.status.rawValue.uppercased()) \($0.name)" }.joined(separator: "\n") + "\n"
    }

    static func humanExplanation(_ explanation: AxolotyCanonicalTestExplanation) -> String {
        let deadline = explanation.timeoutSeconds.map { String($0) } ?? "none"
        var lines = [
            "PLAN \(explanation.name) schema=\(explanation.schemaVersion) ci=\(explanation.ci) deadline=\(deadline)",
        ]
        lines += explanation.nodes.map { node in
            let dependencies = node.dependencies.isEmpty ? "-" : node.dependencies.joined(separator: ",")
            let lane = node.lane ?? "-"
            let resources = node.resources.isEmpty ? "-" : node.resources.joined(separator: ",")
            let artifacts = node.artifacts.isEmpty ? "-" : node.artifacts.joined(separator: ",")
            let arguments = ([node.executable] + node.arguments).map { argument in
                argument.contains(" ") ? "\"\(argument)\"" : argument
            }.joined(separator: " ")
            return "\(node.id): \(arguments)\n"
                + "  depends=\(dependencies) duration=\(node.expectedDurationSeconds)s "
                + "deadline=\(node.timeoutSeconds)s\n"
                + "  policy network=\(node.network.rawValue) broker=\(node.broker.rawValue) "
                + "hardware=\(node.hardware.rawValue) isolation=\(node.isolation.rawValue) "
                + "lane=\(lane) resources=\(resources) artifacts=\(artifacts)"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func manifestDiagnostic(_ error: Error) -> String {
        if let manifestError = error as? AxolotyCanonicalTestManifestError {
            return manifestError.userFriendlyMessage
        }
        return error.localizedDescription
    }

    static func commandResult(_ result: AxolotyCheckCommandResult) -> AxolotyCommandResult {
        AxolotyCommandResult(
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            exitCode: result.exitCode
        )
    }
}
