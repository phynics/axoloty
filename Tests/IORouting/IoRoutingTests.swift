// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Testing

// MARK: - IoAssociationRule tests

@Suite
@MainActor
struct IoAssociationRuleTests {
    @Test
    func testCreateGlobalRule() {
        let rule = IoAssociationRule(
            name: "global",
            valueType: nil,
            condition: { _, _, _, _, _, _ in true }
        )
        #expect(rule.name == "global")
        #expect(rule.valueType == nil)
    }

    @Test
    func testCreateValueTypeRule() {
        let rule = IoAssociationRule(
            name: "temp",
            valueType: "Temperature",
            condition: { _, _, _, _, _, _ in true }
        )
        #expect(rule.name == "temp")
        #expect(rule.valueType == "Temperature")
    }

    @Test
    func testConditionReturnsTrue() {
        let rule = IoAssociationRule(
            name: "always",
            valueType: nil,
            condition: { _, _, _, _, _, _ in true }
        )
        let source = IoSource(valueType: "A")
        let actor = IoActor(valueType: "A")
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [], ioActors: []
        )
        let ctx = IoContext(
            coreType: .IoContext, objectType: "test",
            objectId: CoatyUUID(), name: "ctx"
        )
        let router = RuleBasedIoRouter(
            container: createMinimalContainer(),
            options: ControllerOptions(extra: ["ioContext": ctx]),
            controllerType: "test"
        )
        let result = rule.condition(source, node, actor, node, ctx, router)
        #expect(result == true)
    }

    @Test
    func testConditionReturnsFalse() {
        let rule = IoAssociationRule(
            name: "never",
            valueType: nil,
            condition: { _, _, _, _, _, _ in false }
        )
        let source = IoSource(valueType: "A")
        let actor = IoActor(valueType: "A")
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [], ioActors: []
        )
        let ctx = IoContext(
            coreType: .IoContext, objectType: "test",
            objectId: CoatyUUID(), name: "ctx"
        )
        let router = RuleBasedIoRouter(
            container: createMinimalContainer(),
            options: ControllerOptions(extra: ["ioContext": ctx]),
            controllerType: "test"
        )
        let result = rule.condition(source, node, actor, node, ctx, router)
        #expect(result == false)
    }

    @Test
    func testConditionReturnsNil() {
        let rule = IoAssociationRule(
            name: "nil",
            valueType: nil,
            condition: { _, _, _, _, _, _ in nil }
        )
        let source = IoSource(valueType: "A")
        let actor = IoActor(valueType: "A")
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [], ioActors: []
        )
        let ctx = IoContext(
            coreType: .IoContext, objectType: "test",
            objectId: CoatyUUID(), name: "ctx"
        )
        let router = RuleBasedIoRouter(
            container: createMinimalContainer(),
            options: ControllerOptions(extra: ["ioContext": ctx]),
            controllerType: "test"
        )
        let result = rule.condition(source, node, actor, node, ctx, router)
        #expect(result == nil)
    }
}

// MARK: - RuleBasedIoRouter single-pass evaluation tests

@Suite
@MainActor
struct RuleBasedIoRouterLogicTests {
    @Test
    func testComputeCumulatedUpdateRateBothNil() {
        let router = makeRouter()
        #expect(router.computeCumulatedUpdateRate(rate1: nil, rate2: nil) == nil)
    }

    @Test
    func testComputeCumulatedUpdateRateFirstNil() {
        let router = makeRouter()
        #expect(router.computeCumulatedUpdateRate(rate1: nil, rate2: 100) == 100)
    }

    @Test
    func testComputeCumulatedUpdateRateSecondNil() {
        let router = makeRouter()
        #expect(router.computeCumulatedUpdateRate(rate1: 200, rate2: nil) == 200)
    }

    @Test
    func testComputeCumulatedUpdateRateBothSet() {
        let router = makeRouter()
        #expect(router.computeCumulatedUpdateRate(rate1: 100, rate2: 200) == 200)
    }

    @Test
    func testComputeCumulatedUpdateRateEqualRates() {
        let router = makeRouter()
        #expect(router.computeCumulatedUpdateRate(rate1: 150, rate2: 150) == 150)
    }

    @Test
    func testComputeDefaultUpdateRateBothNil() {
        let router = makeRouter()
        let source = IoSource(valueType: "T", updateRate: nil)
        let actor = IoActor(valueType: "T", updateRate: nil)
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]
        )
        #expect(router.computeDefaultUpdateRate(source: source, actor: actor, sourceNode: node, actorNode: node) == 0)
    }

    @Test
    func testComputeDefaultUpdateRateOnlySourceRate() {
        let router = makeRouter()
        let source = IoSource(valueType: "T", updateRate: 300)
        let actor = IoActor(valueType: "T", updateRate: nil)
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]
        )
        #expect(router.computeDefaultUpdateRate(source: source, actor: actor, sourceNode: node, actorNode: node) == 300)
    }

    @Test
    func testComputeDefaultUpdateRateOnlyActorRate() {
        let router = makeRouter()
        let source = IoSource(valueType: "T", updateRate: nil)
        let actor = IoActor(valueType: "T", updateRate: 500)
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]
        )
        #expect(router.computeDefaultUpdateRate(source: source, actor: actor, sourceNode: node, actorNode: node) == 500)
    }

    @Test
    func testComputeDefaultUpdateRateTakesMax() {
        let router = makeRouter()
        let source = IoSource(valueType: "T", updateRate: 100)
        let actor = IoActor(valueType: "T", updateRate: 1000)
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]
        )
        #expect(router.computeDefaultUpdateRate(source: source, actor: actor, sourceNode: node, actorNode: node) == 1000)
    }

    @Test
    func testAreValueTypesCompatibleSameTypeSameFormat() {
        let router = makeRouter()
        let source = IoSource(valueType: "Temperature", useRawIoValues: false)
        let actor = IoActor(valueType: "Temperature", useRawIoValues: false)
        #expect(router.areValueTypesCompatible(source: source, actor: actor))
    }

    @Test
    func testAreValueTypesCompatibleDifferentType() {
        let router = makeRouter()
        let source = IoSource(valueType: "Temperature")
        let actor = IoActor(valueType: "Pressure")
        #expect(!router.areValueTypesCompatible(source: source, actor: actor))
    }

    @Test
    func testAreValueTypesCompatibleDifferentFormat() {
        let router = makeRouter()
        let source = IoSource(valueType: "Temperature", useRawIoValues: false)
        let actor = IoActor(valueType: "Temperature", useRawIoValues: true)
        #expect(!router.areValueTypesCompatible(source: source, actor: actor))
    }

    @Test
    func testEvaluateRulesWithNoNodesHasNoAssociations() {
        let router = makeRouter()
        router.defineRules(rules: [
            IoAssociationRule(name: "all", valueType: nil, condition: { _, _, _, _, _, _ in true })
        ])
        router.evaluateRules()
        #expect(router.currentAssociations.isEmpty)
    }

    @Test
    func testCompatiblePairAssociatesWithGlobalRule() {
        let router = makeRouter()
        router.defineRules(rules: [
            IoAssociationRule(name: "all", valueType: nil, condition: { _, _, _, _, _, _ in true })
        ])
        let source = IoSource(valueType: "Temperature")
        let actor = IoActor(valueType: "Temperature")
        installNode(router, IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]))
        router.evaluateRules()
        #expect(router.currentAssociations.count == 1)
        #expect(router.currentAssociations[0].0.objectId == source.objectId)
        #expect(router.currentAssociations[0].1.objectId == actor.objectId)
    }

    @Test
    func testIncompatiblePairIsNotAssociated() {
        let router = makeRouter()
        router.defineRules(rules: [
            IoAssociationRule(name: "all", valueType: nil, condition: { _, _, _, _, _, _ in true })
        ])
        let source = IoSource(valueType: "Temperature")
        let actor = IoActor(valueType: "Pressure")
        installNode(router, IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]))
        router.evaluateRules()
        #expect(router.currentAssociations.isEmpty)
    }

    @Test
    func testNoRulesYieldsNoAssociations() {
        let router = makeRouter()
        let source = IoSource(valueType: "T")
        let actor = IoActor(valueType: "T")
        installNode(router, IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]))
        router.evaluateRules()
        #expect(router.currentAssociations.isEmpty)
    }

    @Test
    func testValueTypeSpecificRuleTakesPrecedenceOverGlobal() {
        let router = makeRouter()
        let globalRule = IoAssociationRule(
            name: "global", valueType: nil,
            condition: { _, _, _, _, _, _ in true }
        )
        let specificRule = IoAssociationRule(
            name: "specific", valueType: "Pressure",
            condition: { _, _, _, _, _, _ in false }
        )
        router.defineRules(rules: [globalRule, specificRule])

        let source = IoSource(valueType: "Pressure")
        let actor = IoActor(valueType: "Pressure")
        installNode(router, IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]))
        router.evaluateRules()
        // The specific rule returns false and takes precedence, so no
        // association is made despite the global rule matching.
        #expect(router.currentAssociations.isEmpty)
    }

    @Test
    func testMultipleSourcesAndActorsAllAssociated() {
        let router = makeRouter()
        router.defineRules(rules: [
            IoAssociationRule(name: "all", valueType: nil, condition: { _, _, _, _, _, _ in true })
        ])
        let s1 = IoSource(valueType: "T")
        let s2 = IoSource(valueType: "T")
        let a1 = IoActor(valueType: "T")
        let a2 = IoActor(valueType: "T")
        installNode(router, IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [s1, s2], ioActors: [a1, a2]))
        router.evaluateRules()
        // 2 sources x 2 actors = 4 associations.
        #expect(router.currentAssociations.count == 4)
    }

    @Test
    func testSingleAssociationUsesMaxOfSourceAndActorRate() {
        let router = makeRouter()
        router.defineRules(rules: [
            IoAssociationRule(name: "all", valueType: nil, condition: { _, _, _, _, _, _ in true })
        ])
        let source = IoSource(valueType: "T", updateRate: 100)
        let actor = IoActor(valueType: "T", updateRate: 200)
        installNode(router, IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]))
        router.evaluateRules()
        #expect(router.currentAssociations.count == 1)
        // Per-pair rate = max(source, actor) = max(100, 200) = 200.
        #expect(router.currentAssociations[0].2 == 200)
    }

    @Test
    func testMultipleActorsPerSourceCumulateRate() {
        let router = makeRouter()
        router.defineRules(rules: [
            IoAssociationRule(name: "all", valueType: nil, condition: { _, _, _, _, _, _ in true })
        ])
        let source = IoSource(valueType: "T", updateRate: 100)
        let a1 = IoActor(valueType: "T", updateRate: 200)
        let a2 = IoActor(valueType: "T", updateRate: 500)
        installNode(router, IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [a1, a2]))
        router.evaluateRules()
        #expect(router.currentAssociations.count == 2)
        // Cumulated per source = max(max(100,200), max(100,500)) = max(200, 500) = 500.
        #expect(router.currentAssociations.allSatisfy { $0.2 == 500 })
    }

    @Test
    func testDefineRulesDiscardsPreviousRules() {
        let router = makeRouter()
        let rule1 = IoAssociationRule(
            name: "r1", valueType: nil,
            condition: { _, _, _, _, _, _ in true }
        )
        let rule2 = IoAssociationRule(
            name: "r2", valueType: nil,
            condition: { _, _, _, _, _, _ in false }
        )
        let source = IoSource(valueType: "T")
        let actor = IoActor(valueType: "T")
        installNode(router, IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]))

        router.defineRules(rules: [rule1])
        router.evaluateRules()
        #expect(router.currentAssociations.count == 1)

        // Redefining rules discards rule1; rule2 returns false, so the
        // existing association is disassociated.
        router.defineRules(rules: [rule2])
        #expect(router.currentAssociations.isEmpty)
    }

    @Test
    func testBasicIoRouterAssociatesOnDefaultRule() {
        let ioContext = IoContext(
            coreType: .IoContext, objectType: "test",
            objectId: CoatyUUID(), name: "test"
        )
        let container = createMinimalContainer()
        let router = BasicIoRouter(
            container: container,
            options: ControllerOptions(extra: ["ioContext": ioContext]),
            controllerType: "basic"
        )
        router.onInit()

        let source = IoSource(valueType: "AnyType")
        let actor = IoActor(valueType: "AnyType")
        installNode(router, IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]))
        router.evaluateRules()
        #expect(router.currentAssociations.count == 1)
    }
}

// MARK: - Bucketed incremental evaluation tests

@Suite
@MainActor
struct RuleBasedIoRouterBucketingTests {
    /// A single node advertise must only re-cross the value-type buckets the
    /// advertised node belongs to, not the full source x actor product.
    @Test
    func testSingleAdvertiseConditionInvocationsBoundedByAffectedBucket() {
        let router = makeRouter()
        router.defineRules(rules: [
            IoAssociationRule(name: "all", valueType: nil, condition: { _, _, _, _, _, _ in true })
        ])

        // Spread sources/actors across 60 distinct value types (a few hundred
        // of each: 60 * 5 = 300), one node per bucket, installed without
        // triggering evaluation.
        let valueTypeCount = 60
        let sourcesPerBucket = 5
        let actorsPerBucket = 5
        for b in 0..<valueTypeCount {
            let vt = "T\(b)"
            let sources = (0..<sourcesPerBucket).map { _ in IoSource(valueType: vt) }
            let actors = (0..<actorsPerBucket).map { _ in IoActor(valueType: vt) }
            installNode(router, IoNode(
                coreType: .IoNode, objectType: IoNode.objectType,
                objectId: CoatyUUID(), name: vt,
                ioSources: sources, ioActors: actors))
        }

        // Advertise a single node contributing 1 source + 1 actor to bucket T0.
        let advertisedVt = "T0"
        router.resetConditionInvocationCount()
        advertiseNode(router, IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: advertisedVt,
            ioSources: [IoSource(valueType: advertisedVt)],
            ioActors: [IoActor(valueType: advertisedVt)]))

        // Affected bucket T0 now has (5+1) sources x (5+1) actors = 36 pairs.
        let affectedProduct = (sourcesPerBucket + 1) * (actorsPerBucket + 1)
        // A full cross of every bucket would visit (60-1)*(5*5) + 36 = 1511 pairs.
        let fullCompatiblePairs = (valueTypeCount - 1) * (sourcesPerBucket * actorsPerBucket) + affectedProduct

        // Bound: the single advertise must not exceed the affected bucket's
        // product, and must be strictly less than crossing every bucket.
        #expect(router.conditionInvocationCount <= affectedProduct)
        #expect(router.conditionInvocationCount < fullCompatiblePairs)
        // The advertised bucket's associations were actually established.
        #expect(router.currentAssociations.count == affectedProduct)
    }

    /// A subclass that overrides `areValueTypesCompatible` must fall back to
    /// exhaustive crossing (visiting every candidate pair), so the override is
    /// honored for cross-bucket pairs the default check would reject.
    @Test
    func testOverriddenCompatibilityFallsBackToExhaustiveCrossing() {
        let router = makeCrossBucketRouter()
        #expect(router.usesDefaultValueTypeCompatibility == false)
        router.defineRules(rules: [
            IoAssociationRule(name: "all", valueType: nil, condition: { _, _, _, _, _, _ in true })
        ])

        // 2 sources of type "A" and 2 actors of type "B": all pairs are
        // cross-bucket, so the default (bucketed) check would never cross
        // them. The override accepts every pair, so the exhaustive fallback
        // must cross every source x actor pair (4) and associate them.
        let s1 = IoSource(valueType: "A")
        let s2 = IoSource(valueType: "A")
        let a1 = IoActor(valueType: "B")
        let a2 = IoActor(valueType: "B")
        installNode(router, IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [s1, s2], ioActors: [a1, a2]))

        router.resetConditionInvocationCount()
        router.evaluateRules()

        // Full source x actor crossing: 2 x 2 = 4 pairs, each rule-evaluated.
        #expect(router.conditionInvocationCount == 4)
        #expect(router.currentAssociations.count == 4)
    }

    /// An association whose `associate` publish fails must be left out of
    /// `currentAssociations` so the next evaluation republishes it.
    @Test
    func testFailedAssociatePublishIsRetriedOnNextEvaluation() {
        let router = makeRouter()
        // An ioContext name containing '/' is not a valid event type filter,
        // so `publishAssociate` throws `AxolotyError.invalidArgument` before
        // reaching the broker (no live broker needed for this test).
        router.ioContext.name = "bad/context"
        router.defineRules(rules: [
            IoAssociationRule(name: "all", valueType: nil, condition: { _, _, _, _, _, _ in true })
        ])

        let source = IoSource(valueType: "T")
        let actor = IoActor(valueType: "T")
        installNode(router, IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]))

        router.evaluateRules()
        // Publish failed: the pair must NOT be recorded as current.
        #expect(router.currentAssociations.isEmpty)

        // Fix the ioContext name: the pair is still absent from
        // `currentAssociations`, so the next evaluation sees it as new and
        // republishes.
        router.ioContext.name = "valid"
        router.evaluateRules()
        #expect(router.currentAssociations.count == 1)
        let recorded = router.currentAssociations[0]
        #expect(recorded.0.objectId == source.objectId)
        #expect(recorded.1.objectId == actor.objectId)
    }

    /// An incremental (single-node-advertise) evaluation must reconcile only
    /// the advertised node's buckets; associations in untouched buckets are
    /// left intact rather than torn down.
    @Test
    func testIncrementalEvaluationLeavesUntouchedBucketsIntact() {
        let router = makeRouter()
        router.defineRules(rules: [
            IoAssociationRule(name: "all", valueType: nil, condition: { _, _, _, _, _, _ in true })
        ])

        let sA = IoSource(valueType: "A")
        let aA = IoActor(valueType: "A")
        let sB = IoSource(valueType: "B")
        let aB = IoActor(valueType: "B")
        installNode(router, IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "A",
            ioSources: [sA], ioActors: [aA]))
        installNode(router, IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "B",
            ioSources: [sB], ioActors: [aB]))

        router.evaluateRules()
        #expect(router.currentAssociations.count == 2)

        // Advertise a new source in bucket A only.
        let sA2 = IoSource(valueType: "A")
        advertiseNode(router, IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "A",
            ioSources: [sA2], ioActors: []))

        // Bucket A now has 2 sources x 1 actor = 2 associations; bucket B
        // must remain associated (1) -> 3 total.
        #expect(router.currentAssociations.count == 3)
        let bStillAssociated = router.currentAssociations.contains { info in
            info.0.objectId == sB.objectId && info.1.objectId == aB.objectId
        }
        #expect(bStillAssociated)
    }
}

// MARK: - Helpers

/// A `RuleBasedIoRouter` subclass that overrides `areValueTypesCompatible` to
/// accept every pair (including cross-bucket ones the default check rejects).
/// Because it is not one of the framework's known non-overriding router types,
/// the router falls back to exhaustive crossing, which consults this override
/// for every candidate pair.
final class CrossBucketRouter: RuleBasedIoRouter {
    override func areValueTypesCompatible(source: IoSource, actor: IoActor) -> Bool {
        return true
    }
}

@MainActor
private func createMinimalContainer() -> Container {
    let options = CommunicationOptions(
        mqttClientOptions: MQTTClientOptions(),
        shouldAutoStart: false
    )
    let config = Configuration(
        common: CommonOptions(),
        communication: options
    )
    let components = Components(controllers: [:], objectTypes: [])
    return Container.resolve(components: components, configuration: config)
}

@MainActor
private func makeRouter() -> RuleBasedIoRouter {
    let ioContext = IoContext(
        coreType: .IoContext, objectType: "test",
        objectId: CoatyUUID(), name: "test"
    )
    let container = createMinimalContainer()
    let router = RuleBasedIoRouter(
        container: container,
        options: ControllerOptions(extra: ["ioContext": ioContext]),
        controllerType: "test"
    )
    router.onInit()
    return router
}

@MainActor
private func makeCrossBucketRouter() -> CrossBucketRouter {
    let ioContext = IoContext(
        coreType: .IoContext, objectType: "test",
        objectId: CoatyUUID(), name: "test"
    )
    let container = createMinimalContainer()
    let router = CrossBucketRouter(
        container: container,
        options: ControllerOptions(extra: ["ioContext": ioContext]),
        controllerType: "crossbucket"
    )
    router.onInit()
    return router
}

/// Registers a node's IO points (in `managedIoNodes` and the bucketed index)
/// WITHOUT triggering rule evaluation, mirroring the base class's
/// `managedIoNodes` update without the `onIoNodeManaged` hook. Used to stage
/// the pre-existing router state before a measured advertise.
@MainActor
private func installNode(_ router: RuleBasedIoRouter, _ node: IoNode) {
    router.managedIoNodes[node.objectId.string] = node
    router.registerIoNodeInIndex(node)
}

/// Simulates a node advertise: registers the node in `managedIoNodes` and
/// the index, then invokes `onIoNodeManaged` (which triggers the incremental
/// rule evaluation that tests measure).
@MainActor
private func advertiseNode(_ router: RuleBasedIoRouter, _ node: IoNode) {
    router.managedIoNodes[node.objectId.string] = node
    router.onIoNodeManaged(node: node)
}
