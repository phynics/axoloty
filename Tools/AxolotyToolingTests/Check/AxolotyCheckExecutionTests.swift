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

    #expect(results.count == 1)
    #expect(results[0].name == "success")
    #expect(results[0].status == .passed)
    #expect(results[0].command == AxolotyCheckCommandResult(exitCode: 0, standardOutput: "success"))
    #expect(results[0].timing?.elapsedSeconds ?? -1 >= 0)
    #expect(results[0].timing?.resourceLeaseWaitSeconds ?? -1 >= 0)
}

@Test
func overrunWarningsAreSingleNonFatalAndCancelledAfterCompletion() {
    let clock = CheckTestClock()
    let scheduler = ManualOverrunScheduler()
    let events = CheckEventRecorder()
    let plan = AxolotyCheckPlan(
        nodes: [AxolotyCheckNode(
            name: "slow",
            command: AxolotyCommandPlan(executable: "slow", timeoutSeconds: 10),
            expectedDurationSeconds: 5
        )],
        deadlineSeconds: 10,
        expectedDurationSeconds: 4
    )
    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )

    let results = AxolotyCheckExecutor(
        commandRunner: OverrunFiringRunner(clock: clock, scheduler: scheduler),
        contextValidator: validator,
        clock: clock,
        overrunScheduler: scheduler,
        eventSink: events.append
    ).execute(plan)

    #expect(results.map(\.status) == [.passed])
    #expect(results.first?.timing == AxolotyCheckTiming(
        elapsedSeconds: 6,
        expectedDurationSeconds: 5,
        resourceLeaseWaitSeconds: 0
    ))
    #expect(events.events.map(\.kind) == [
        .planStarted, .nodeStarted, .planOverrun, .nodeOverrun, .nodeCompleted, .planCompleted,
    ])
    let completion = events.events.first { $0.kind == .nodeCompleted }
    #expect(completion?.status == .passed)
    #expect(completion?.lastTest == "last-test")
    #expect(completion?.outputBytes == 42)
    #expect(completion?.artifactPath == "/artifacts/slow")
    scheduler.fireAll()
    #expect(events.events.filter { $0.kind == .nodeOverrun }.count == 1)
    #expect(events.events.filter { $0.kind == .planOverrun }.count == 1)
}

@Test
func skippedNodeHasNoTimingStartOrOverrunEvent() throws {
    let scheduler = ManualOverrunScheduler()
    let events = CheckEventRecorder()
    let plan = try AxolotyCheckPlanner().plan([
        AxolotyCheckNode(
            name: "blocked",
            dependencies: ["failed"],
            command: AxolotyCommandPlan(executable: "blocked"),
            expectedDurationSeconds: 1
        ),
        node("failed"),
    ])

    let results = AxolotyCheckExecutor(
        commandRunner: StubCommandRunner(failedCommands: ["failed"]),
        contextValidator: AxolotyExecutionContextValidator(),
        overrunScheduler: scheduler,
        eventSink: events.append
    ).execute(plan)

    let blocked = try #require(results.first { $0.name == "blocked" })
    #expect(blocked.status == .skipped)
    #expect(blocked.timing == nil)
    #expect(!events.events.contains { $0.node == "blocked" && [.nodeStarted, .nodeOverrun].contains($0.kind) })
    #expect(events.events.contains { $0.node == "blocked" && $0.kind == .nodeCompleted })
}

}
