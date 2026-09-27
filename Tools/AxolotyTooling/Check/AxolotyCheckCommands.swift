// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A typed check-family command routed by ``AxolotyCheckCommands``.
enum AxolotyCheckCommand: Equatable, Sendable {
    case plan
    case check(requested: [String]?)
    case build
    case testOffline
    case testTooling
    case verify(ci: Bool)
    case testOne(filter: String, repetition: AxolotyTestRepetition?)
    case testTier(name: String, ci: Bool)
    case explain(tier: String, ci: Bool)
    case integration
}

/// Executes canonical checks, plans, and check-oriented compatibility aliases.
struct AxolotyCheckCommands: Sendable {
    private let commandRunner: any AxolotyCheckCommandRunning
    private let contextValidator: AxolotyExecutionContextValidator
    private let outputMode: AxolotyCommandOutputMode
    private let planResolver: Result<AxolotyCanonicalTestPlanResolver, AxolotyCanonicalTestManifestError>
    private let executor: AxolotyCheckExecutor

    init(
        commandRunner: any AxolotyCheckCommandRunning,
        contextValidator: AxolotyExecutionContextValidator,
        outputMode: AxolotyCommandOutputMode,
        planResolver: Result<AxolotyCanonicalTestPlanResolver, AxolotyCanonicalTestManifestError>,
        executor: AxolotyCheckExecutor
    ) {
        self.commandRunner = commandRunner
        self.contextValidator = contextValidator
        self.outputMode = outputMode
        self.planResolver = planResolver
        self.executor = executor
    }

    /// Executes one typed check-family command.
    func run(_ command: AxolotyCheckCommand) -> AxolotyCommandResult {
        switch command {
        case .plan:
            return planResult()
        case .check(let requested):
            return checkResult(requested: requested)
        case .build:
            return checkResult(requested: ["build"])
        case .testOffline:
            return checkResult(requested: nil)
        case .testTooling:
            return checkResult(requested: ["test-tooling"])
        case .verify(let ci):
            return verifyResult(ci: ci)
        case .testOne(let filter, let repetition):
            return testOneResult(filter: filter, repetition: repetition)
        case .testTier(let name, let ci):
            return testTierResult(tier: name, ci: ci)
        case .explain(let tier, let ci):
            return explainResult(tier: tier, ci: ci)
        case .integration:
            return AxolotyCommandResult(
                standardError: "error: broker-backed integration tier is retired; use a declared test tier or wire capture for broker evidence\n",
                exitCode: 69
            )
        }
    }

    private func planResult() -> AxolotyCommandResult {
        do {
            let resolver = try planResolver.get()
            let plan = try resolver.resolve(.tier(
                name: CanonicalTier.ci.rawValue,
                ci: false,
                platform: AxolotyCheckPlan.currentPlatform
            ))
            return try AxolotyCommandFamilySupport.jsonResult(plan)
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(AxolotyCommandFamilySupport.manifestDiagnostic(error))\n",
                exitCode: 70
            )
        }
    }

    private func checkResult(requested: [String]? = nil) -> AxolotyCommandResult {
        do {
            let resolver = try planResolver.get()
            let plan = try resolver.resolve(.tier(
                name: CanonicalTier.ci.rawValue,
                ci: false,
                platform: AxolotyCheckPlan.currentPlatform,
                requested: requested
            ))
            let results = executor.execute(plan)
            let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
            return AxolotyCommandFamilySupport.manifestResult(
                AxolotyCheckManifest(results: results),
                outputMode: outputMode,
                exitCode: exitCode
            )
        } catch AxolotyCanonicalTestManifestError.unavailableNode(_) {
            return AxolotyCommandResult(
                standardError: "error: requested check is unavailable on this platform\n",
                exitCode: 69
            )
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(AxolotyCommandFamilySupport.manifestDiagnostic(error))\n",
                exitCode: 70
            )
        }
    }

    private func verifyResult(ci: Bool) -> AxolotyCommandResult {
        do {
            let resolver = try planResolver.get()
            let plan = try resolver.resolve(.tier(
                name: CanonicalTier.ci.rawValue,
                ci: ci,
                platform: AxolotyCheckPlan.currentPlatform
            ))
            return execute(plan: plan, writeVerificationReport: ci)
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(AxolotyCommandFamilySupport.manifestDiagnostic(error))\n",
                exitCode: 70
            )
        }
    }

    private func testOneResult(
        filter: String,
        repetition: AxolotyTestRepetition?
    ) -> AxolotyCommandResult {
        guard !filter.isEmpty else {
            return AxolotyCommandResult(
                standardError: "error: test-one requires a non-empty FILTER or --filter value\n",
                exitCode: 64
            )
        }
        do {
            let resolver = try planResolver.get()
            let commands = try resolver.testOneCommands(
                filter: filter,
                repetition: repetition,
                platform: AxolotyCheckPlan.currentPlatform
            )
            var searchedPackages: [String] = []
            var lastEmptyResult: AxolotyCheckCommandResult?
            for command in commands {
                searchedPackages.append(Self.packageLabel(of: command))
                if let failure = contextValidator.failureResult(validating: [command]) {
                    return AxolotyCommandFamilySupport.commandResult(failure)
                }
                let result = execute(command, context: AxolotyCommandRunContext(node: "test-one", stage: "check"))
                guard result.exitCode == FoundationCommandExecution.emptyTestRunExitCode else {
                    return Self.testOneResult(result, outputMode: outputMode)
                }
                lastEmptyResult = result
            }
            // Every candidate compiled and ran, but none selected a test. Say
            // which packages were searched instead of leaving only the last
            // package's empty Swift Testing output.
            let searched = searchedPackages.joined(separator: ", ")
            let diagnostic = "error: no tests matched FILTER=\"\(filter)\" in any searched package: \(searched)\n"
            let result = AxolotyCheckCommandResult(
                exitCode: FoundationCommandExecution.emptyTestRunExitCode,
                standardOutput: lastEmptyResult?.standardOutput ?? "",
                standardError: diagnostic
            )
            let wrapped = Self.testOneResult(result, outputMode: outputMode)
            return AxolotyCommandResult(
                standardOutput: wrapped.standardOutput,
                standardError: wrapped.standardError + diagnostic,
                exitCode: wrapped.exitCode
            )
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(AxolotyCommandFamilySupport.manifestDiagnostic(error))\n",
                exitCode: 70
            )
        }
    }

    /// Wraps one finished `test-one` command as a one-node manifest result.
    private static func testOneResult(
        _ result: AxolotyCheckCommandResult,
        outputMode: AxolotyCommandOutputMode
    ) -> AxolotyCommandResult {
        let check = AxolotyCheckResult(
            name: "test-one",
            status: result.exitCode == 0 ? .passed : .failed,
            command: result
        )
        return AxolotyCommandFamilySupport.manifestResult(
            AxolotyCheckManifest(results: [check]),
            outputMode: outputMode,
            exitCode: result.exitCode == 0 ? 0 : 1
        )
    }

    /// The package a candidate command targets, for the no-match diagnostic.
    private static func packageLabel(of command: AxolotyCommandPlan) -> String {
        guard let index = command.arguments.firstIndex(of: "--package-path"),
              command.arguments.index(after: index) < command.arguments.endIndex else {
            return "root (.)"
        }
        return command.arguments[command.arguments.index(after: index)]
    }

    private func testTierResult(tier: String, ci: Bool) -> AxolotyCommandResult {
        guard !tier.isEmpty else {
            return AxolotyCommandResult(
                standardError: "error: test-tier requires a non-empty TIER or tier argument\n",
                exitCode: 64
            )
        }
        do {
            let resolver = try planResolver.get()
            let plan = try resolver.resolve(.tier(
                name: tier,
                ci: ci,
                platform: AxolotyCheckPlan.currentPlatform
            ))
            return execute(plan: plan)
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(AxolotyCommandFamilySupport.manifestDiagnostic(error))\n",
                exitCode: 69
            )
        }
    }

    private func explainResult(tier: String, ci: Bool) -> AxolotyCommandResult {
        guard !tier.isEmpty else {
            return AxolotyCommandResult(
                standardError: "error: explain requires a non-empty TIER or tier argument\n",
                exitCode: 64
            )
        }
        do {
            let resolver = try planResolver.get()
            let explanation = try resolver.explanation(for: .tier(
                name: tier,
                ci: ci,
                platform: AxolotyCheckPlan.currentPlatform
            ))
            if outputMode == .json {
                return try AxolotyCommandFamilySupport.jsonResult(explanation)
            }
            return AxolotyCommandResult(
                standardOutput: AxolotyCommandFamilySupport.humanExplanation(explanation)
            )
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(AxolotyCommandFamilySupport.manifestDiagnostic(error))\n",
                exitCode: 69
            )
        }
    }

    private func execute(
        plan availablePlan: AxolotyCheckPlan,
        writeVerificationReport: Bool = false
    ) -> AxolotyCommandResult {
        let results = executor.execute(availablePlan)
        let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
        if writeVerificationReport {
            guard let invocation = (commandRunner as? any AxolotyArtifactInvocationIdentifying)?.artifactInvocation else {
                return AxolotyCommandResult(
                    standardError: "error: verify-ci command runner does not expose an artifact invocation\n",
                    exitCode: 70
                )
            }
            do {
                _ = try AxolotyVerificationReportWriter().write(
                    plan: availablePlan,
                    results: results,
                    invocation: invocation
                )
            } catch {
                return AxolotyCommandResult(
                    standardError: "error: unable to publish verify-ci report: \(error.localizedDescription)\n",
                    exitCode: 70
                )
            }
        }
        return AxolotyCommandFamilySupport.manifestResult(
            AxolotyCheckManifest(results: results),
            outputMode: outputMode,
            exitCode: exitCode
        )
    }

    private func execute(
        _ command: AxolotyCommandPlan,
        context: AxolotyCommandRunContext
    ) -> AxolotyCheckCommandResult {
        if let lifecycleRunner = commandRunner as? any AxolotyLifecycleCommandRunning {
            return lifecycleRunner.run(command, context: context)
        }
        return commandRunner.run(command)
    }
}
