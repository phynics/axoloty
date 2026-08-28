// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

extension AxolotyCheckTests {

@Test
func checkpointPlansResolveReleaseSnapshotPlaceholders() throws {
    let source = "Tests/Fixtures/custom"
    let destination = ".testing/custom-release"
    let plans = [
        AxolotyCheckPlan.checkpoint(
            source: source,
            destination: destination,
            consumerEnvironment: [:]
        ),
        AxolotyCheckPlan.checkpointHardware(
            source: source,
            destination: destination
        ),
    ]

    for plan in plans {
        let generate = try #require(plan.nodes.first { $0.name.hasSuffix("fixture-bundle-generate") })
        let verify = try #require(plan.nodes.first { $0.name.hasSuffix("fixture-bundle-verify") })
        #expect(generate.command.arguments == [
            "Tests/Support/fixture-bundle.mjs", "generate", source, destination,
        ])
        #expect(verify.command.arguments == [
            "Tests/Support/fixture-bundle.mjs", "verify", destination,
        ])
        #expect(!generate.command.arguments.contains("${SOURCE}"))
        #expect(!generate.command.arguments.contains("${DESTINATION}"))
    }
}

@Test
func hardwareCheckpointInheritsEveryOrdinaryCheckpointNode() throws {
    let manifest = try AxolotyCanonicalTestManifest.loadDefault()
    let checkpoint = try manifest.plan(named: "checkpoint")
    let hardware = try manifest.plan(named: "checkpoint-hardware")
    let hardwareNames = Set(hardware.nodes.map(\.name))

    #expect(Set(checkpoint.nodes.map(\.name)).isSubset(of: hardwareNames))
    #expect(hardwareNames.contains("checkpoint-hardware-smoke"))
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
    let plan = try AxolotyCheckPlanner().plan(AxolotyCheckPlan.initialOffline.nodes)
    let data = try JSONEncoder().encode(plan)
    #expect(try JSONDecoder().decode(AxolotyCheckPlan.self, from: data) == plan)
}

@Test
func legacySchemaV1PlanDefaultsMissingExecutionContextAndReencodesItExplicitly() throws {
    let fixture = try #require(Bundle.module.url(
        forResource: "legacy-check-plan-v1",
        withExtension: "json"
    ))
    let plan = try JSONDecoder().decode(
        AxolotyCheckPlan.self,
        from: Data(contentsOf: fixture)
    )

    #expect(plan.schemaVersion == 1)
    #expect(plan.nodes.first?.command.executionContext == .project)

    let encoded = try JSONEncoder().encode(plan)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let nodes = try #require(object["nodes"] as? [[String: Any]])
    let command = try #require(nodes.first?["command"] as? [String: Any])
    #expect(command["executionContext"] as? String == "project")
}

@Test
func offlinePlanOmitsEmbeddedChecksOnMacOS() {
    let plan = AxolotyCheckPlan.initialOffline(for: .macOS)
    #expect(!plan.nodes.contains { $0.name.hasPrefix("embedded-") })
    #expect(!plan.nodes.contains { ["support-container", "support-fuzz-runner"].contains($0.name) })
}

@Test
func offlinePlanIncludesEmbeddedChecksOnLinux() {
    let plan = AxolotyCheckPlan.initialOffline(for: .linux)
    let names = plan.nodes.map(\.name)
    let embeddedBuild = names.firstIndex(of: "embedded-build")
    let embeddedLinker = names.firstIndex(of: "embedded-linker")
    let boundedHost = names.firstIndex(of: "g1-bounded-runtime-host")
    let boundedSanitized = names.firstIndex(of: "g1-bounded-runtime-sanitized")
    let boundedEmbedded = names.firstIndex(of: "g1-bounded-runtime-embedded")
    let objectBoundary = names.firstIndex(of: "g3-object-boundary")
    let objectPackage = names.firstIndex(of: "g3-object-model-package")
    let objectTests = names.firstIndex(of: "g3-object-model-tests")
    let objectMacros = names.firstIndex(of: "g3-object-macros-tests")
    let coatyModels = names.firstIndex(of: "g3-coaty-models-tests")
    let objectHost = names.firstIndex(of: "g3-object-model-evidence-host")
    let objectSanitized = names.firstIndex(of: "g3-object-model-evidence-sanitized")
    let objectEmbedded = names.firstIndex(of: "g3-object-model-evidence-embedded")

    #expect(embeddedBuild != nil)
    #expect(embeddedLinker != nil)
    #expect(boundedHost != nil)
    #expect(boundedSanitized != nil)
    #expect(boundedEmbedded != nil)
    #expect(objectBoundary != nil)
    #expect(objectPackage != nil)
    #expect(objectTests != nil)
    #expect(objectMacros != nil)
    #expect(coatyModels != nil)
    #expect(objectHost != nil)
    #expect(objectSanitized != nil)
    #expect(objectEmbedded != nil)
    if let embeddedBuild, let embeddedLinker, let boundedHost, let boundedSanitized, let boundedEmbedded,
       let objectBoundary, let objectPackage, let objectTests, let objectMacros, let coatyModels,
       let objectHost, let objectSanitized, let objectEmbedded {
        #expect(embeddedBuild < embeddedLinker)
        #expect(embeddedLinker < boundedHost)
        #expect(boundedHost < boundedSanitized)
        #expect(boundedSanitized < boundedEmbedded)
        #expect(boundedEmbedded < objectBoundary)
        #expect(objectBoundary < objectPackage)
        #expect(objectPackage < objectTests)
        #expect(objectTests < objectMacros)
        #expect(objectMacros < coatyModels)
        #expect(coatyModels < objectHost)
        #expect(objectHost < objectSanitized)
        #expect(objectSanitized < objectEmbedded)
    }
}

}
