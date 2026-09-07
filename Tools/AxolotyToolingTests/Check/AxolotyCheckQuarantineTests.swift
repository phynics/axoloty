// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

private struct QuarantineStubCommandRunner: AxolotyLifecycleCommandRunning {
    let failedTestNamesByNode: [String: Set<String>]

    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        AxolotyCheckCommandResult(exitCode: 1)
    }

    func run(_ command: AxolotyCommandPlan, context: AxolotyCommandRunContext) -> AxolotyCheckCommandResult {
        guard let node = context.node, let failedTestNames = failedTestNamesByNode[node] else {
            return AxolotyCheckCommandResult(exitCode: 0)
        }
        return AxolotyCheckCommandResult(
            exitCode: 1,
            standardError: "1 issue",
            observation: AxolotyCommandObservation(
                elapsedSeconds: 0,
                lastTest: failedTestNames.first,
                outputBytes: 0,
                artifactPath: "/tmp",
                failedTestNames: failedTestNames
            )
        )
    }
}

private func quarantineEntry(
    prefixes: [String],
    nodeIds: [String],
    deadline: String = "2099-01-01"
) -> AxolotyQuarantineEntry {
    AxolotyQuarantineEntry(
        id: "q-fixture",
        testNamePrefixes: prefixes,
        nodeIds: nodeIds,
        owner: "someone",
        ticket: "#781",
        evidence: "https://example.invalid/comment",
        deadline: deadline,
        reason: "fixture"
    )
}

extension AxolotyCheckTests {

@Test
func executorDowngradesANodeWhoseOnlyFailuresAreQuarantined() throws {
    let plan = try AxolotyCheckPlanner().plan([node("flaky")])
    let executor = AxolotyCheckExecutor(
        commandRunner: QuarantineStubCommandRunner(failedTestNamesByNode: ["flaky": ["commandRunnerFlakesSometimes()"]]),
        quarantine: AxolotyQuarantineLedger(
            entries: [quarantineEntry(prefixes: ["commandRunner"], nodeIds: ["flaky"])],
            now: Date()
        )
    )

    let results = executor.execute(plan)

    #expect(results.map(\.status) == [.passed])
    // The underlying failure is never discarded, only the node's status.
    #expect(results[0].command?.exitCode == 1)
    #expect(results[0].command?.observation?.failedTestNames == ["commandRunnerFlakesSometimes()"])
}

@Test
func executorDoesNotDowngradeANodeWithANonQuarantinedFailure() throws {
    let plan = try AxolotyCheckPlanner().plan([node("flaky")])
    let executor = AxolotyCheckExecutor(
        commandRunner: QuarantineStubCommandRunner(failedTestNamesByNode: [
            "flaky": ["commandRunnerFlakesSometimes()", "aRealRegression()"],
        ]),
        quarantine: AxolotyQuarantineLedger(
            entries: [quarantineEntry(prefixes: ["commandRunner"], nodeIds: ["flaky"])],
            now: Date()
        )
    )

    let results = executor.execute(plan)

    #expect(results.map(\.status) == [.failed])
}

@Test
func executorDoesNotDowngradeAFailureQuarantinedForAnotherNode() throws {
    let plan = try AxolotyCheckPlanner().plan([node("flaky")])
    let executor = AxolotyCheckExecutor(
        commandRunner: QuarantineStubCommandRunner(failedTestNamesByNode: ["flaky": ["commandRunnerFlakesSometimes()"]]),
        quarantine: AxolotyQuarantineLedger(
            entries: [quarantineEntry(prefixes: ["commandRunner"], nodeIds: ["a-different-node"])],
            now: Date()
        )
    )

    let results = executor.execute(plan)

    #expect(results.map(\.status) == [.failed])
}

@Test
func executorDoesNotDowngradeAnExpiredQuarantineEntry() throws {
    let plan = try AxolotyCheckPlanner().plan([node("flaky")])
    let executor = AxolotyCheckExecutor(
        commandRunner: QuarantineStubCommandRunner(failedTestNamesByNode: ["flaky": ["commandRunnerFlakesSometimes()"]]),
        quarantine: AxolotyQuarantineLedger(
            entries: [quarantineEntry(prefixes: ["commandRunner"], nodeIds: ["flaky"], deadline: "2020-01-01")],
            now: Date()
        )
    )

    let results = executor.execute(plan)

    #expect(results.map(\.status) == [.failed])
}

}
