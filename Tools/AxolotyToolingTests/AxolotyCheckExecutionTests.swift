// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

extension AxolotyCheckTests {

@Test
func executorRunsIndependentNodesAfterFailure() throws {
    let plan = try AxolotyCheckPlanner().plan([
        node("blocked", dependencies: ["failed"]),
        node("independent"),
        node("failed"),
    ])

    let results = AxolotyCheckExecutor(commandRunner: StubCommandRunner(failedCommands: ["failed"])).execute(plan)

    #expect(results.map(\.name) == ["failed", "blocked", "independent"])
    #expect(results.map(\.status) == [.failed, .skipped, .passed])
    #expect(results[1].command == nil)
}

@Test
func executorPassesRemainingPlanBudgetAndContinuesIndependentNodesAfterFailure() throws {
    let clock = CheckTestClock()
    let runner = DeadlineRecordingRunner(
        clock: clock,
        failedCommands: ["failed"],
        advancePerCommand: 3
    )
    let plan = try AxolotyCheckPlanner().plan(
        [
            node("blocked", dependencies: ["failed"]),
            node("independent"),
            AxolotyCheckNode(
                name: "failed",
                command: AxolotyCommandPlan(executable: "failed", timeoutSeconds: 2)
            ),
        ],
        deadlineSeconds: 10
    )
    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )

    let results = AxolotyCheckExecutor(
        commandRunner: runner,
        contextValidator: validator,
        clock: clock
    ).execute(plan)

    #expect(results.map(\.status) == [.failed, .skipped, .passed])
    #expect(runner.commands.map(\.executable) == ["failed", "independent"])
    #expect(runner.commands.map(\.timeoutSeconds) == [2, 7])
}

@Test
func executorMarksAllPendingNodesExpiredWhenACommandExceedsPlanDeadline() throws {
    let clock = CheckTestClock()
    let runner = DeadlineRecordingRunner(clock: clock, advancePerCommand: 6)
    let plan = try AxolotyCheckPlanner().plan(
        [
            node("dependent", dependencies: ["first"]),
            node("independent"),
            node("first"),
        ],
        deadlineSeconds: 5
    )
    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )

    let results = AxolotyCheckExecutor(
        commandRunner: runner,
        contextValidator: validator,
        clock: clock
    ).execute(plan)

    #expect(results.map(\.status) == [.failed, .expired, .expired])
    #expect(runner.commands.map(\.executable) == ["first"])
    #expect(results[0].command?.exitCode == 124)
    #expect(results[0].command?.standardError ==
        "check plan deadline exceeded after node completed: node=first elapsed=6.000s budget=5.000s\n")
    #expect(results[1].command?.standardError ==
        "check plan deadline exceeded before node started: node=dependent elapsed=6.000s budget=5.000s dependencies=first\n")
}

@Test
func executorCapturesCommandResult() throws {
    let plan = try AxolotyCheckPlanner().plan([node("success")])

    let results = AxolotyCheckExecutor(commandRunner: StubCommandRunner(failedCommands: [])).execute(plan)

    #expect(results == [
        AxolotyCheckResult(
            name: "success",
            status: .passed,
            command: AxolotyCheckCommandResult(exitCode: 0, standardOutput: "success")
        ),
    ])
}

}
