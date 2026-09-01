// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

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
    private let clock: any AxolotyTimingClock
    private let resourceLeaseManager: any AxolotyResourceLeasing
    private let overrunScheduler: any AxolotyOverrunScheduling
    private let eventSink: @Sendable (AxolotyCheckExecutionEvent) -> Void

    private static let crossProcessResources: Set<String> = [
        "fixed-port-1883",
        "wire-containers"
    ]
    private static let resourceLeaseWaitBudgetSeconds: TimeInterval = 30

    /// Creates an executor with the command runner used for every node.
    ///
    /// - Parameter commandRunner: The boundary that starts child commands.
    public init(
        commandRunner: any AxolotyCheckCommandRunning,
        cancellation: AxolotyCommandCancellation? = nil,
        resourceLeaseManager: (any AxolotyResourceLeasing)? = nil,
        eventSink: @escaping @Sendable (AxolotyCheckExecutionEvent) -> Void = { _ in }
    ) {
        self.init(
            commandRunner: commandRunner,
            contextValidator: AxolotyExecutionContextValidator(),
            cancellation: cancellation,
            resourceLeaseManager: resourceLeaseManager,
            eventSink: eventSink
        )
    }

    init(
        commandRunner: any AxolotyCheckCommandRunning,
        contextValidator: AxolotyExecutionContextValidator,
        cancellation: AxolotyCommandCancellation? = nil,
        clock: any AxolotyTimingClock = AxolotyContinuousTimingClock(),
        resourceLeaseManager: (any AxolotyResourceLeasing)? = nil,
        overrunScheduler: any AxolotyOverrunScheduling = DispatchOverrunScheduler(),
        eventSink: @escaping @Sendable (AxolotyCheckExecutionEvent) -> Void = { _ in }
    ) {
        self.commandRunner = commandRunner
        self.contextValidator = contextValidator
        self.cancellation = cancellation
        self.clock = clock
        self.overrunScheduler = overrunScheduler
        self.eventSink = eventSink
        self.resourceLeaseManager = resourceLeaseManager
            ?? FoundationResourceLeaseManager(environment: contextValidator.environment)
    }

    /// Runs a plan in dependency order, serializing every graph node.
    ///
    /// A node whose prerequisite failed or was skipped is skipped without
    /// invoking the runner. Execution continues after independent failures so
    /// the manifest describes every planned check.
    /// Independent nodes are intentionally not run concurrently. This serial
    /// graph boundary preserves canonical lanes and separate-process or
    /// exclusive isolation declarations. Named external resources that can
    /// collide across independent invocations are leased only while their
    /// owning command runs; commands may still use their own internal test
    /// parallelism.
    ///
    /// - Parameter plan: The plan to execute.
    /// - Returns: Results in the plan's deterministic order.
    public func execute(_ plan: AxolotyCheckPlan) -> [AxolotyCheckResult] {
        let planStartedAt = clock.now()
        let planDeadline = plan.deadlineSeconds.map { planStartedAt + $0 }
        eventSink(AxolotyCheckExecutionEvent(
            kind: .planStarted,
            expectedDurationSeconds: plan.expectedDurationSeconds
        ))
        let planWarning = plan.expectedDurationSeconds.map { expectation in
            overrunScheduler.schedule(after: expectation) { [clock, eventSink] in
                eventSink(AxolotyCheckExecutionEvent(
                    kind: .planOverrun,
                    elapsedSeconds: max(0, clock.now() - planStartedAt),
                    expectedDurationSeconds: expectation
                ))
            }
        }
        let validator = contextValidator
        let diagnostics = plan.nodes.reduce(
            into: [String: AxolotyExecutionContextDiagnostic]()
        ) { diagnostics, node in
            if let diagnostic = validator.validate(node.command) {
                diagnostics[node.name] = diagnostic
            }
        }
        if !diagnostics.isEmpty {
            let results = plan.nodes.map { node in
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
            for (node, result) in zip(plan.nodes, results) {
                emitNodeCompletion(node: node, status: result.status, timing: nil, command: result.command)
            }
            completePlan(results, plan: plan, startedAt: planStartedAt, warning: planWarning)
            return results
        }
        var statuses: [String: AxolotyCheckStatus] = [:]
        var results: [AxolotyCheckResult] = []

        for node in plan.nodes {
            if cancellation?.isCancelled == true {
                statuses[node.name] = .skipped
                let result = AxolotyCheckResult(name: node.name, status: .skipped)
                results.append(result)
                emitNodeCompletion(node: node, status: .skipped, timing: nil, command: nil)
                continue
            }
            let nodeReadyAt = clock.now()
            if let planDeadline, nodeReadyAt >= planDeadline {
                statuses[node.name] = .expired
                let result = Self.expiredResult(
                    node: node,
                    planStartedAt: planStartedAt,
                    planDeadline: planDeadline,
                    now: nodeReadyAt
                )
                results.append(result)
                emitNodeCompletion(node: node, status: .expired, timing: nil, command: result.command)
                continue
            }
            guard node.dependencies.allSatisfy({ statuses[$0] == .passed }) else {
                statuses[node.name] = .skipped
                results.append(AxolotyCheckResult(name: node.name, status: .skipped))
                emitNodeCompletion(node: node, status: .skipped, timing: nil, command: nil)
                continue
            }

            let nodeStartedAt = clock.now()
            eventSink(AxolotyCheckExecutionEvent(
                kind: .nodeStarted,
                node: node.name,
                expectedDurationSeconds: node.expectedDurationSeconds,
                resourceLeaseWaitSeconds: 0
            ))
            let nodeWarning = node.expectedDurationSeconds.map { expectation in
                overrunScheduler.schedule(after: expectation) { [clock, eventSink] in
                    eventSink(AxolotyCheckExecutionEvent(
                        kind: .nodeOverrun,
                        node: node.name,
                        elapsedSeconds: max(0, clock.now() - nodeStartedAt),
                        expectedDurationSeconds: expectation
                    ))
                }
            }
            let command = Self.commandBoundedByPlanDeadline(
                node.command,
                planDeadline: planDeadline,
                now: nodeReadyAt
            )
            let resourceLeases: [any AxolotyResourceLease]
            let leasesStartedAt = clock.now()
            do {
                resourceLeases = try acquireResourceLeases(
                    for: node,
                    planDeadline: planDeadline,
                    command: command
                )
            } catch {
                nodeWarning?.cancel()
                let finishedAt = clock.now()
                let timing = AxolotyCheckTiming(
                    elapsedSeconds: max(0, finishedAt - nodeStartedAt),
                    expectedDurationSeconds: node.expectedDurationSeconds,
                    resourceLeaseWaitSeconds: max(0, finishedAt - leasesStartedAt)
                )
                let commandResult = AxolotyCheckCommandResult(
                    exitCode: 75,
                    standardError: "unable to acquire resource lease: \(error.localizedDescription)\n"
                )
                statuses[node.name] = .failed
                results.append(AxolotyCheckResult(
                    name: node.name,
                    status: .failed,
                    command: commandResult,
                    timing: timing
                ))
                emitNodeCompletion(node: node, status: .failed, timing: timing, command: commandResult)
                continue
            }
            let leasesAcquiredAt = clock.now()
            let commandResult = withExtendedLifetime(resourceLeases) {
                if let lifecycleRunner = commandRunner as? any AxolotyLifecycleCommandRunning {
                    return lifecycleRunner.run(
                        command,
                        context: AxolotyCommandRunContext(node: node.name, stage: "check")
                    )
                }
                return commandRunner.run(command)
            }
            let finishedAt = clock.now()
            nodeWarning?.cancel()
            let result = Self.resultAfterPlanDeadline(
                commandResult,
                node: node,
                planStartedAt: planStartedAt,
                planDeadline: planDeadline,
                finishedAt: finishedAt
            )
            let status: AxolotyCheckStatus = result.exitCode == 0 ? .passed : .failed
            statuses[node.name] = status
            let timing = AxolotyCheckTiming(
                elapsedSeconds: max(0, finishedAt - nodeStartedAt),
                expectedDurationSeconds: node.expectedDurationSeconds,
                resourceLeaseWaitSeconds: max(0, leasesAcquiredAt - leasesStartedAt)
            )
            results.append(AxolotyCheckResult(
                name: node.name,
                status: status,
                command: result,
                timing: timing
            ))
            emitNodeCompletion(node: node, status: status, timing: timing, command: result)
        }

        completePlan(results, plan: plan, startedAt: planStartedAt, warning: planWarning)
        return results
    }

    private func emitNodeCompletion(
        node: AxolotyCheckNode,
        status: AxolotyCheckStatus,
        timing: AxolotyCheckTiming?,
        command: AxolotyCheckCommandResult?
    ) {
        eventSink(AxolotyCheckExecutionEvent(
            kind: .nodeCompleted,
            node: node.name,
            status: status,
            elapsedSeconds: timing?.elapsedSeconds,
            expectedDurationSeconds: timing?.expectedDurationSeconds ?? node.expectedDurationSeconds,
            resourceLeaseWaitSeconds: timing?.resourceLeaseWaitSeconds,
            lastTest: command?.observation?.lastTest ?? command?.lifecycle?.lastTest,
            outputBytes: command?.observation?.outputBytes ?? command?.lifecycle?.outputBytes,
            artifactPath: command?.observation?.artifactPath ?? command?.lifecycle?.artifactPath
        ))
    }

    private func completePlan(
        _ results: [AxolotyCheckResult],
        plan: AxolotyCheckPlan,
        startedAt: TimeInterval,
        warning: (any AxolotyOverrunCancellation)?
    ) {
        warning?.cancel()
        let commands = results.compactMap(\.command)
        let lastTest = commands.compactMap { $0.observation?.lastTest ?? $0.lifecycle?.lastTest }.last
        let artifactPath = commands.compactMap {
            $0.observation?.artifactPath ?? $0.lifecycle?.artifactPath
        }.last
        let outputBytes = commands.compactMap {
            $0.observation?.outputBytes ?? $0.lifecycle?.outputBytes
        }.reduce(0, +)
        eventSink(AxolotyCheckExecutionEvent(
            kind: .planCompleted,
            status: results.allSatisfy { $0.status == .passed } ? .passed : .failed,
            elapsedSeconds: max(0, clock.now() - startedAt),
            expectedDurationSeconds: plan.expectedDurationSeconds,
            resourceLeaseWaitSeconds: results.compactMap(\.timing).reduce(0) { $0 + $1.resourceLeaseWaitSeconds },
            lastTest: lastTest,
            outputBytes: outputBytes,
            artifactPath: artifactPath
        ))
    }

    private func acquireResourceLeases(
        for node: AxolotyCheckNode,
        planDeadline: TimeInterval?,
        command: AxolotyCommandPlan
    ) throws -> [any AxolotyResourceLease] {
        let resources = node.resources
            .filter { Self.crossProcessResources.contains($0) }
            .sorted()
        var leases: [any AxolotyResourceLease] = []
        leases.reserveCapacity(resources.count)
        for resource in resources {
            let remaining = planDeadline.map { max(0, $0 - clock.now()) }
            let timeout: TimeInterval? = if let remaining {
                command.timeoutSeconds.map { commandSeconds in
                    min(commandSeconds, remaining, Self.resourceLeaseWaitBudgetSeconds)
                } ?? min(remaining, Self.resourceLeaseWaitBudgetSeconds)
            } else {
                min(command.timeoutSeconds ?? Self.resourceLeaseWaitBudgetSeconds, Self.resourceLeaseWaitBudgetSeconds)
            }
            leases.append(try resourceLeaseManager.acquire(
                resource: resource,
                timeoutSeconds: timeout,
                owner: "check-node=\(node.name)"
            ))
        }
        return leases
    }

    private static func commandBoundedByPlanDeadline(
        _ command: AxolotyCommandPlan,
        planDeadline: TimeInterval?,
        now: TimeInterval
    ) -> AxolotyCommandPlan {
        guard let planDeadline else { return command }
        let remaining = planDeadline - now
        let timeout = command.timeoutSeconds.map { min($0, remaining) } ?? remaining
        return AxolotyCommandPlan(
            executable: command.executable,
            arguments: command.arguments,
            environment: command.environment,
            executionContext: command.executionContext,
            timeoutSeconds: timeout
        )
    }

    private static func expiredResult(
        node: AxolotyCheckNode,
        planStartedAt: TimeInterval,
        planDeadline: TimeInterval,
        now: TimeInterval
    ) -> AxolotyCheckResult {
        let elapsed = max(0, now - planStartedAt)
        let dependencies = node.dependencies.isEmpty ? "none" : node.dependencies.joined(separator: ",")
        let diagnostic = String(
            format: "check plan deadline exceeded before node started: node=%@ elapsed=%.3fs budget=%.3fs dependencies=%@\n",
            locale: Locale(identifier: "en_US_POSIX"),
            node.name,
            elapsed,
            max(0, planDeadline - planStartedAt),
            dependencies
        )
        return AxolotyCheckResult(
            name: node.name,
            status: .expired,
            command: AxolotyCheckCommandResult(exitCode: 124, standardError: diagnostic)
        )
    }

    private static func resultAfterPlanDeadline(
        _ result: AxolotyCheckCommandResult,
        node: AxolotyCheckNode,
        planStartedAt: TimeInterval,
        planDeadline: TimeInterval?,
        finishedAt: TimeInterval
    ) -> AxolotyCheckCommandResult {
        guard let planDeadline, finishedAt >= planDeadline else { return result }
        let elapsed = max(0, finishedAt - planStartedAt)
        let diagnostic = String(
            format: "check plan deadline exceeded after node completed: node=%@ elapsed=%.3fs budget=%.3fs\n",
            locale: Locale(identifier: "en_US_POSIX"),
            node.name,
            elapsed,
            max(0, planDeadline - planStartedAt)
        )
        var standardError = result.standardError
        if !standardError.isEmpty, !standardError.hasSuffix("\n") { standardError.append("\n") }
        standardError.append(diagnostic)
        return AxolotyCheckCommandResult(
            exitCode: result.exitCode == 0 ? 124 : result.exitCode,
            standardOutput: result.standardOutput,
            standardError: standardError,
            lifecycle: result.lifecycle,
            observation: result.observation
        )
    }
}
