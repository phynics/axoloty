// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

extension AxolotyCheckTests {

    @Test
    func schedulerRunsIndependentEligibleNodesAndReturnsStablePlanOrder() throws {
        let runner = ConcurrentCheckRunner(requiredOverlap: ["first", "independent"])
        let plan = try AxolotyCheckPlanner().plan([
            parallelCheckNode("first"),
            parallelCheckNode("independent"),
            parallelCheckNode("dependent", dependencies: ["first"]),
        ])

        let executor = AxolotyCheckExecutor(
            commandRunner: runner,
            contextValidator: AxolotyExecutionContextValidator(environment: ["AXOLOTY_DEVCONTAINER": "1"]),
            schedulingConfiguration: schedulingConfiguration(concurrency: 3)
        )
        var observedNames: [[String]] = []
        var observedStatuses: [[AxolotyCheckStatus]] = []
        for _ in 0..<3 {
            let results = executor.execute(plan)
            observedNames.append(results.map(\.name))
            observedStatuses.append(results.map(\.status))
        }

        #expect(runner.maximumConcurrent >= 2)
        #expect(observedNames == Array(repeating: ["first", "independent", "dependent"], count: 3))
        #expect(observedStatuses == Array(repeating: [.passed, .passed, .passed], count: 3))
        #expect(runner.completedBeforeStart("first", dependent: "dependent"))
    }

    @Test
    func schedulerKeepsSerialNodesExclusiveAndBoundsParallelNodes() throws {
        let runner = ConcurrentCheckRunner(requiredOverlap: ["parallel-a", "parallel-b"])
        let plan = try AxolotyCheckPlanner().plan([
            parallelCheckNode("parallel-a"),
            parallelCheckNode("parallel-b"),
            AxolotyCheckNode(name: "serial", command: AxolotyCommandPlan(executable: "serial")),
            parallelCheckNode("parallel-c"),
        ])

        let results = AxolotyCheckExecutor(
            commandRunner: runner,
            contextValidator: AxolotyExecutionContextValidator(environment: ["AXOLOTY_DEVCONTAINER": "1"]),
            schedulingConfiguration: schedulingConfiguration(concurrency: 2)
        ).execute(plan)

        #expect(results.allSatisfy { $0.status == .passed })
        #expect(runner.maximumConcurrent == 2)
        #expect(runner.startedWithoutActiveCommand("serial"))
    }

    @Test
    func schedulerDoesNotRunDependantsAfterFailureAndNamesTheBlocker() throws {
        let runner = ConcurrentCheckRunner(failedCommands: ["failed"])
        let plan = try AxolotyCheckPlanner().plan([
            parallelCheckNode("failed"),
            parallelCheckNode("blocked", dependencies: ["failed"]),
            parallelCheckNode("independent"),
        ])

        let results = AxolotyCheckExecutor(
            commandRunner: runner,
            contextValidator: AxolotyExecutionContextValidator(environment: ["AXOLOTY_DEVCONTAINER": "1"]),
            schedulingConfiguration: schedulingConfiguration(concurrency: 3)
        ).execute(plan)

        let blocked = try #require(results.first { $0.name == "blocked" })
        #expect(results.map(\.status) == [.failed, .skipped, .passed])
        #expect(blocked.blockingDependency == "failed")
        #expect(!runner.didStart("blocked"))
        #expect(runner.didStart("independent"))
    }

    @Test
    func schedulerRejectsCyclesAndMissingDependenciesBeforeLaunching() {
        let runner = ConcurrentCheckRunner()
        let executor = AxolotyCheckExecutor(
            commandRunner: runner,
            contextValidator: AxolotyExecutionContextValidator(environment: ["AXOLOTY_DEVCONTAINER": "1"]),
            schedulingConfiguration: schedulingConfiguration(concurrency: 2)
        )
        let cyclic = AxolotyCheckPlan(nodes: [
            parallelCheckNode("a", dependencies: ["b"]),
            parallelCheckNode("b", dependencies: ["a"]),
        ])
        let missing = AxolotyCheckPlan(nodes: [parallelCheckNode("orphan", dependencies: ["missing"])])

        let cyclicResults = executor.execute(cyclic)
        let missingResults = executor.execute(missing)

        #expect(cyclicResults.map(\.status) == [.failed, .failed])
        #expect(cyclicResults.first?.command?.standardError.contains("dependency cycle") == true)
        #expect(missingResults.map(\.status) == [.failed])
        #expect(missingResults.first?.command?.standardError.contains("missing node missing") == true)
        #expect(runner.started.isEmpty)
    }

    @Test
    func schedulerCancellationSkipsPendingNodesWithoutStartingCommands() throws {
        let cancellation = AxolotyCommandCancellation()
        cancellation.cancel()
        let runner = ConcurrentCheckRunner()
        let plan = try AxolotyCheckPlanner().plan([
            parallelCheckNode("one"),
            parallelCheckNode("two"),
        ])

        let results = AxolotyCheckExecutor(
            commandRunner: runner,
            contextValidator: AxolotyExecutionContextValidator(environment: ["AXOLOTY_DEVCONTAINER": "1"]),
            cancellation: cancellation,
            schedulingConfiguration: schedulingConfiguration(concurrency: 2)
        ).execute(plan)

        #expect(results.map(\.status) == [.skipped, .skipped])
        #expect(runner.started.isEmpty)
    }

    @Test
    func schedulerResourceClaimsAllowReadersButBlockSharedScratchWriters() {
        let readerA = parallelCheckNode("reader-a", resources: ["source-tree"], sharedResources: ["source-tree"])
        let readerB = parallelCheckNode("reader-b", resources: ["source-tree"], sharedResources: ["source-tree"])
        let writer = parallelCheckNode("writer", resources: ["source-tree"])
        let compilerA = parallelCheckNode("compiler-a", resources: ["swiftpm-scratch"])
        let compilerB = parallelCheckNode("compiler-b", resources: ["swiftpm-scratch"])
        let laneA = parallelCheckNode("lane-a", lane: "compiler-lane")
        let laneB = parallelCheckNode("lane-b", lane: "compiler-lane")
        var claims = AxolotyCheckResourceClaims()

        #expect(claims.canAcquire(readerA))
        claims.acquire(readerA)
        #expect(claims.canAcquire(readerB))
        #expect(!claims.canAcquire(writer))
        claims.release(readerA)
        #expect(claims.canAcquire(writer))
        claims.acquire(compilerA)
        #expect(!claims.canAcquire(compilerB))
        claims.release(compilerA)
        #expect(claims.canAcquire(compilerB))
        claims.acquire(laneA)
        #expect(!claims.canAcquire(laneB))
        claims.release(laneA)
        #expect(claims.canAcquire(laneB))
    }

    @Test
    func schedulerUsesCpuMemoryAndOperatorBudgets() {
        let twoGiB: UInt64 = 2 * 1_024 * 1_024 * 1_024
        #expect(AxolotyCheckSchedulingConfiguration(
            environment: [:],
            processorCount: 8,
            availableMemoryBytes: 3 * twoGiB
        ).maxConcurrentNodes == 3)
        #expect(AxolotyCheckSchedulingConfiguration(
            environment: ["AXOLOTY_CHECK_CONCURRENCY": ""],
            processorCount: 4,
            availableMemoryBytes: 8 * twoGiB
        ).maxConcurrentNodes == 4)
        #expect(AxolotyCheckSchedulingConfiguration(
            environment: ["AXOLOTY_CHECK_CONCURRENCY": "2"],
            processorCount: 8,
            availableMemoryBytes: 8 * twoGiB
        ).maxConcurrentNodes == 2)
        #expect(AxolotyCheckSchedulingConfiguration(
            environment: ["AXOLOTY_CHECK_CONCURRENCY": "99"],
            processorCount: 2,
            availableMemoryBytes: 8 * twoGiB
        ).maxConcurrentNodes == 2)
        #expect(AxolotyCheckSchedulingConfiguration(
            environment: ["AXOLOTY_CHECK_CONCURRENCY": "1"],
            processorCount: 8,
            availableMemoryBytes: 8 * twoGiB
        ).maxConcurrentNodes == 1)
        #expect(AxolotyCheckSchedulingConfiguration(
            environment: ["AXOLOTY_CHECK_CONCURRENCY": "invalid"],
            processorCount: 8,
            availableMemoryBytes: 8 * twoGiB
        ).maxConcurrentNodes == 1)
    }
}

private func parallelCheckNode(
    _ name: String,
    dependencies: [String] = [],
    resources: [String] = [],
    sharedResources: [String] = [],
    lane: String? = nil
) -> AxolotyCheckNode {
    AxolotyCheckNode(
        name: name,
        dependencies: dependencies,
        command: AxolotyCommandPlan(executable: name),
        resources: resources,
        sharedResources: sharedResources,
        parallelSafe: true,
        lane: lane,
        isolation: .parallel
    )
}

private func schedulingConfiguration(concurrency: Int) -> AxolotyCheckSchedulingConfiguration {
    AxolotyCheckSchedulingConfiguration(
        environment: ["AXOLOTY_CHECK_CONCURRENCY": String(concurrency)],
        processorCount: 4,
        availableMemoryBytes: 8 * 1_024 * 1_024 * 1_024
    )
}

private final class ConcurrentCheckRunner: AxolotyCheckCommandRunning, @unchecked Sendable {
    private let condition = NSCondition()
    private let requiredOverlap: Set<String>
    private let failedCommands: Set<String>
    private var active = 0
    private var maximum = 0
    private var storedStarted: [String] = []
    private var storedCompleted: [String] = []
    private var activeAtStart: [String: Int] = [:]
    private var sequence = 0
    private var startSequence: [String: Int] = [:]
    private var completionSequence: [String: Int] = [:]

    init(requiredOverlap: Set<String> = [], failedCommands: Set<String> = []) {
        self.requiredOverlap = requiredOverlap
        self.failedCommands = failedCommands
    }

    var maximumConcurrent: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximum
    }

    var started: [String] {
        condition.lock()
        defer { condition.unlock() }
        return storedStarted
    }

    func didStart(_ name: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return storedStarted.contains(name)
    }

    func startedWithoutActiveCommand(_ name: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return activeAtStart[name] == 0
    }

    func completedBeforeStart(_ earlier: String, dependent: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard let completedAt = completionSequence[earlier],
              let startedAt = startSequence[dependent] else { return false }
        return completedAt < startedAt
    }

    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        condition.lock()
        active += 1
        maximum = max(maximum, active)
        storedStarted.append(command.executable)
        sequence += 1
        startSequence[command.executable] = sequence
        activeAtStart[command.executable] = active - 1
        condition.broadcast()
        if requiredOverlap.contains(command.executable) {
            let deadline = Date(timeIntervalSinceNow: 2)
            while active < 2, Date() < deadline {
                _ = condition.wait(until: deadline)
            }
        }
        condition.unlock()

        Thread.sleep(forTimeInterval: 0.03)

        condition.lock()
        storedCompleted.append(command.executable)
        sequence += 1
        completionSequence[command.executable] = sequence
        active -= 1
        condition.broadcast()
        condition.unlock()
        return AxolotyCheckCommandResult(
            exitCode: failedCommands.contains(command.executable) ? 1 : 0,
            standardOutput: command.executable
        )
    }
}
