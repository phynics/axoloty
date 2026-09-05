// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A typed wire-family command routed by ``AxolotyWireCommands``.
enum AxolotyWireCommand: Equatable, Sendable {
    case verifyFixtures
    case capture
}

/// Executes offline wire verification and live wire-capture commands.
struct AxolotyWireCommands: Sendable {
    private let environment: [String: String]
    private let outputMode: AxolotyCommandOutputMode
    private let planResolver: Result<AxolotyCanonicalTestPlanResolver, AxolotyCanonicalTestManifestError>
    private let executor: AxolotyCheckExecutor

    init(
        environment: [String: String],
        outputMode: AxolotyCommandOutputMode,
        planResolver: Result<AxolotyCanonicalTestPlanResolver, AxolotyCanonicalTestManifestError>,
        executor: AxolotyCheckExecutor
    ) {
        self.environment = environment
        self.outputMode = outputMode
        self.planResolver = planResolver
        self.executor = executor
    }

    /// Executes one typed wire-family command.
    func run(_ command: AxolotyWireCommand) -> AxolotyCommandResult {
        switch command {
        case .verifyFixtures:
            return wireFixturesResult()
        case .capture:
            return wireCaptureResult()
        }
    }

    private func wireFixturesResult() -> AxolotyCommandResult {
        do {
            let resolver = try planResolver.get()
            let plan = try resolver.resolve(.tier(
                name: CanonicalTier.ci.rawValue,
                ci: false,
                platform: AxolotyCheckPlan.currentPlatform,
                requested: ["test-wire"]
            ))
            let results = executor.execute(plan)
            let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
            return AxolotyCommandFamilySupport.manifestResult(
                AxolotyCheckManifest(results: results),
                outputMode: outputMode,
                exitCode: exitCode
            )
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(AxolotyCommandFamilySupport.manifestDiagnostic(error))\n",
                exitCode: 70
            )
        }
    }

    private func wireCaptureResult() -> AxolotyCommandResult {
        do {
            let resolver = try planResolver.get()
            let plan = try resolver.resolve(.wireCapture(
                environment: environment,
                platform: AxolotyCheckPlan.currentPlatform
            ))
            let results = executor.execute(plan)
            let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
            return AxolotyCommandFamilySupport.manifestResult(
                AxolotyCheckManifest(results: results),
                outputMode: outputMode,
                exitCode: exitCode
            )
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(AxolotyCommandFamilySupport.manifestDiagnostic(error))\n",
                exitCode: 70
            )
        }
    }
}
