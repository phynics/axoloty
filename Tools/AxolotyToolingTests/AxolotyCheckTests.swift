// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyTooling
import Foundation
import Testing

private func node(_ name: String, dependencies: [String] = []) -> AxolotyCheckNode {
    AxolotyCheckNode(name: name, dependencies: dependencies, command: AxolotyCommandPlan(executable: name))
}

private struct StubCommandRunner: AxolotyCheckCommandRunning {
    let failedCommands: Set<String>

    func run(_ command: AxolotyCommandPlan) throws -> AxolotyCheckCommandResult {
        AxolotyCheckCommandResult(
            exitCode: failedCommands.contains(command.executable) ? 1 : 0,
            standardOutput: command.executable
        )
    }
}

@Test
func plannerOrdersDependenciesBeforeDependants() throws {
    let plan = try AxolotyCheckPlanner().plan([node("app", dependencies: ["core"]), node("core")])
    #expect(plan.nodes.map(\.name) == ["core", "app"])
}

@Test
func plannerCoalescesDuplicatePrerequisites() throws {
    let plan = try AxolotyCheckPlanner().plan([
        node("root", dependencies: ["left", "right"]),
        node("left", dependencies: ["shared"]),
        node("right", dependencies: ["shared"]),
        node("shared"),
    ])
    #expect(plan.nodes.map(\.name) == ["shared", "left", "right", "root"])
}

@Test
func plannerReportsMissingDependency() {
    do {
        _ = try AxolotyCheckPlanner().plan([node("root", dependencies: ["missing"])])
        Issue.record("Expected missing dependency")
    } catch let error as AxolotyCheckPlanningError {
        #expect(error == .missingDependency(node: "root", dependency: "missing"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func plannerReportsCycles() {
    do {
        _ = try AxolotyCheckPlanner().plan([node("a", dependencies: ["b"]), node("b", dependencies: ["a"])])
        Issue.record("Expected cycle")
    } catch let error as AxolotyCheckPlanningError {
        #expect(error == .cycle(["a", "b", "a"]))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func modelsEncodeAndDecode() throws {
    let plan = try AxolotyCheckPlanner().plan(AxolotyCheckPlan.canonicalNonHardware.nodes)
    let data = try JSONEncoder().encode(plan)
    #expect(try JSONDecoder().decode(AxolotyCheckPlan.self, from: data) == plan)
}

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
