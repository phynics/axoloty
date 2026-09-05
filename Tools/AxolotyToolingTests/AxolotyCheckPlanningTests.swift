// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

extension AxolotyCheckTests {

@Test
func checkpointPlansCarryNoUnresolvedPlaceholders() throws {
    // Release snapshot placeholders existed only for fixture-bundle nodes.
    // With bundle generation removed, no checkpoint command may still carry an
    // unsubstituted placeholder.
    let resolver = try AxolotyCanonicalTestPlanResolver(environment: ProcessInfo.processInfo.environment)
    let plans = [
        try resolver.resolve(.checkpoint(
            hardwareDevice: nil,
            consumerEnvironment: [:],
            platform: AxolotyCheckPlan.currentPlatform
        )),
        try resolver.resolve(.checkpoint(
            hardwareDevice: "/dev/ttyACM0",
            consumerEnvironment: [:],
            platform: AxolotyCheckPlan.currentPlatform
        )),
    ]

    for plan in plans {
        #expect(!plan.nodes.isEmpty)
        for node in plan.nodes {
            for argument in [node.command.executable] + node.command.arguments {
                #expect(!argument.contains("${"), "unresolved placeholder in \(node.name): \(argument)")
            }
            #expect(!node.command.executable.hasSuffix("fixture-bundle.mjs"))
        }
    }
}

@Test
func canonicalManifestAndExecutablePlansUseIndependentSchemaVersions() throws {
    let resolver = try AxolotyCanonicalTestPlanResolver(environment: ProcessInfo.processInfo.environment)
    // Every declared category must resolve, and the manifest and the plans it
    // produces version independently.
    #expect(Set(resolver.manifest.tiers.map(\.id)) == Set(CanonicalTier.allCases.map(\.rawValue)))
    let plans = try resolver.manifest.tiers.map { tier in
        try resolver.resolve(.tier(
            name: tier.id,
            ci: false,
            platform: AxolotyCheckPlan.currentPlatform
        ))
    }

    #expect(resolver.manifest.schemaVersion == 2)
    #expect(plans.allSatisfy { $0.schemaVersion == 1 })
}

@Test
func injectedManifestSchemaIsValidatedBeforeResolution() throws {
    let resolver = try AxolotyCanonicalTestPlanResolver(environment: ProcessInfo.processInfo.environment)
    let invalid = AxolotyCanonicalTestManifest(
        schemaVersion: 1,
        manifestID: resolver.manifest.manifestID,
        nodes: resolver.manifest.nodes,
        tiers: resolver.manifest.tiers,
        requiredGates: resolver.manifest.requiredGates,
        testOne: resolver.manifest.testOne,
        selfTests: resolver.manifest.selfTests,
        artifactContract: resolver.manifest.artifactContract,
        flakePolicy: resolver.manifest.flakePolicy
    )

    #expect(throws: AxolotyCanonicalTestManifestError.unsupportedSchema(1)) {
        _ = try AxolotyCanonicalTestPlanResolver(manifest: invalid).resolve(.tier(name: CanonicalTier.ci.rawValue, ci: false,
            platform: AxolotyCheckPlan.currentPlatform,
            requested: nil
        ))
    }
}

@Test
func releaseCategoryDeclaresEveryOtherCategoryAndRunsWhatItCan() throws {
    // release declares the full scope of a release. Categories marked attested
    // are proved by recorded evidence instead of being run inside it, so they
    // belong to its declared nodes but not to its resolved plan.
    let resolver = try AxolotyCanonicalTestPlanResolver(environment: ProcessInfo.processInfo.environment)
    let declared = try #require(resolver.manifest.tiers.first { $0.id == "release" }).nodes
    func resolved(_ tier: CanonicalTier) throws -> Set<String> {
        Set(try resolver.resolve(.tier(
            name: tier.rawValue,
            ci: false,
            platform: .linux
        )).nodes.map(\.name))
    }
    let release = try resolved(.release)
    for narrower in [CanonicalTier.ci, .wire, .embedded] {
        let tier = try #require(resolver.manifest.tiers.first { $0.id == narrower.rawValue })
        #expect(Set(tier.nodes).isSubset(of: Set(declared)), "\(narrower.rawValue) must be declared by release")
        if tier.attested {
            #expect(Set(tier.nodes).isDisjoint(with: release), "\(narrower.rawValue) is attested, not run inside release")
            #expect(!(try resolved(narrower)).isEmpty, "\(narrower.rawValue) must still resolve on its own")
        } else {
            #expect(try resolved(narrower).isSubset(of: release), "\(narrower.rawValue) must run inside release")
        }
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
    let resolver = try AxolotyCanonicalTestPlanResolver(environment: ProcessInfo.processInfo.environment)
    let plan = try resolver.resolve(.tier(name: CanonicalTier.ci.rawValue, ci: false,
        platform: AxolotyCheckPlan.currentPlatform,
        requested: nil
    ))
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
    #expect(plan.expectedDurationSeconds == nil)
    #expect(plan.nodes.first?.expectedDurationSeconds == nil)

    let encoded = try JSONEncoder().encode(plan)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let nodes = try #require(object["nodes"] as? [[String: Any]])
    let command = try #require(nodes.first?["command"] as? [String: Any])
    #expect(command["executionContext"] as? String == "project")
}

@Test
func verifyPlanPropagatesCalibratedTimingExpectations() throws {
    let resolver = try AxolotyCanonicalTestPlanResolver(environment: ProcessInfo.processInfo.environment)
    let plan = try resolver.resolve(.tier(name: CanonicalTier.ci.rawValue, ci: true, platform: .linux, requested: nil))
    let expectations = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.name, $0.expectedDurationSeconds) })

    #expect(plan.schemaVersion == 1)
    #expect(plan.expectedDurationSeconds == 1_200)
    #expect(plan.deadlineSeconds == 3_600)
    #expect(expectations["embedded-build"] == 180)
    #expect(expectations["g4-static-runtime"] == 120)
    #expect(expectations["g2-trace-corpus"] == 90)
    #expect(expectations["wire-distribution"] == 60)
}

@Test
func schemaV2CheckPlanIsRejected() throws {
    let fixture = try #require(Bundle.module.url(
        forResource: "legacy-check-plan-v1",
        withExtension: "json"
    ))
    var document = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any]
    )
    document["schemaVersion"] = 2

    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(
            AxolotyCheckPlan.self,
            from: JSONSerialization.data(withJSONObject: document)
        )
    }
}

@Test
func offlinePlanOmitsEmbeddedChecksOnMacOS() throws {
    let resolver = try AxolotyCanonicalTestPlanResolver(environment: ProcessInfo.processInfo.environment)
    let plan = try resolver.resolve(.tier(name: CanonicalTier.ci.rawValue, ci: false, platform: .macOS, requested: nil))
    #expect(!plan.nodes.contains { $0.name.hasPrefix("embedded-") })
    #expect(!plan.nodes.contains { ["support-container"].contains($0.name) })
}

@Test
func offlinePlanIncludesEmbeddedChecksOnLinux() throws {
    let resolver = try AxolotyCanonicalTestPlanResolver(environment: ProcessInfo.processInfo.environment)
    let plan = try resolver.resolve(.tier(name: CanonicalTier.ci.rawValue, ci: false, platform: .linux, requested: nil))
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

@Test
func namedPlanRejectsRequestedNodesOutsideItsResolvedClosure() throws {
    let resolver = try AxolotyCanonicalTestPlanResolver(
        environment: ProcessInfo.processInfo.environment
    )

    #expect(throws: AxolotyCanonicalTestManifestError.unavailableNode(
        "checkpoint-hardware-smoke"
    )) {
        _ = try resolver.resolve(.tier(name: CanonicalTier.ci.rawValue, ci: false,
            platform: .linux,
            requested: ["checkpoint-hardware-smoke"]
        ))
    }
}

}
