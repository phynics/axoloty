// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Testing

// MARK: - IoAssociationRule tests

@Suite
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

// MARK: - IoCompatibleAssociation tests

@Suite
struct IoCompatibleAssociationTests {
    @Test
    func testCreateAssociation() {
        let source = IoSource(valueType: "Temperature")
        let actor = IoActor(valueType: "Temperature")
        let sourceNode = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "sourceNode",
            ioSources: [source], ioActors: []
        )
        let actorNode = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "actorNode",
            ioSources: [], ioActors: [actor]
        )
        let assoc = IoCompatibleAssociation(source, sourceNode, actor, actorNode)

        #expect(assoc.source.objectId == source.objectId)
        #expect(assoc.sourceNode.objectId == sourceNode.objectId)
        #expect(assoc.actor.objectId == actor.objectId)
        #expect(assoc.actorNode.objectId == actorNode.objectId)
    }
}

// MARK: - RuleBasedIoRouter pure-logic tests

@Suite
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
    func testDefineRulesDiscardsPrevious() {
        let router = makeRouter()
        let rule1 = IoAssociationRule(
            name: "r1", valueType: nil,
            condition: { _, _, _, _, _, _ in true }
        )
        let rule2 = IoAssociationRule(
            name: "r2", valueType: nil,
            condition: { _, _, _, _, _, _ in false }
        )
        router.defineRules(rules: [rule1])
        router.defineRules(rules: [rule2])
        // After redefinition, only rule2 should be in effect
        let source = IoSource(valueType: "T")
        let actor = IoActor(valueType: "T")
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source, IoSource(valueType: "T")],
            ioActors: [actor, IoActor(valueType: "T")]
        )
        router.managedIoNodes[node.objectId.string] = node
        let assocs = router.getCompatibleAssociations()
        let matched = router.match(compatibleAssociations: assocs)
        #expect(matched.isEmpty)
    }

    @Test
    func testGetCompatibleAssociationsEmptyNodes() {
        let router = makeRouter()
        let assocs = router.getCompatibleAssociations()
        #expect(assocs.isEmpty)
    }

    @Test
    func testGetCompatibleAssociationsWithMatchingTypes() {
        let router = makeRouter()
        let source = IoSource(valueType: "Temperature")
        let actor = IoActor(valueType: "Temperature")
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]
        )
        router.managedIoNodes[node.objectId.string] = node
        let assocs = router.getCompatibleAssociations()
        #expect(assocs.count == 1)
        #expect(assocs[0].source.objectId == source.objectId)
        #expect(assocs[0].actor.objectId == actor.objectId)
    }

    @Test
    func testGetCompatibleAssociationsFiltersByType() {
        let router = makeRouter()
        let source = IoSource(valueType: "Temperature")
        let actor = IoActor(valueType: "Pressure")
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]
        )
        router.managedIoNodes[node.objectId.string] = node
        let assocs = router.getCompatibleAssociations()
        #expect(assocs.isEmpty)
    }

    @Test
    func testMatchWithGlobalRule() {
        let router = makeRouter()
        let rule = IoAssociationRule(
            name: "global", valueType: nil,
            condition: { _, _, _, _, _, _ in true }
        )
        router.defineRules(rules: [rule])

        let source = IoSource(valueType: "T")
        let actor = IoActor(valueType: "T")
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]
        )
        router.managedIoNodes[node.objectId.string] = node
        let assocs = router.getCompatibleAssociations()
        let matched = router.match(compatibleAssociations: assocs)
        #expect(matched.count == 1)
        let actors = matched[source.objectId.string]
        #expect(actors != nil)
        #expect(actors!.count == 1)
    }

    @Test
    func testMatchWithoutRules() {
        let router = makeRouter()
        let source = IoSource(valueType: "T")
        let actor = IoActor(valueType: "T")
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]
        )
        router.managedIoNodes[node.objectId.string] = node
        let assocs = router.getCompatibleAssociations()
        let matched = router.match(compatibleAssociations: assocs)
        #expect(matched.isEmpty)
    }

    @Test
    func testMatchPrefersValueTypeRuleOverGlobal() {
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
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]
        )
        router.managedIoNodes[node.objectId.string] = node
        let assocs = router.getCompatibleAssociations()
        let matched = router.match(compatibleAssociations: assocs)
        // The specific rule returns false, so no association should be made
        // despite the global rule matching
        #expect(matched.isEmpty)
    }

    @Test
    func testMatchMultipleSourcesAndActors() {
        let router = makeRouter()
        let rule = IoAssociationRule(
            name: "all", valueType: nil,
            condition: { _, _, _, _, _, _ in true }
        )
        router.defineRules(rules: [rule])

        let s1 = IoSource(valueType: "T")
        let s2 = IoSource(valueType: "T")
        let a1 = IoActor(valueType: "T")
        let a2 = IoActor(valueType: "T")
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [s1, s2], ioActors: [a1, a2]
        )
        router.managedIoNodes[node.objectId.string] = node
        let assocs = router.getCompatibleAssociations()
        // 2 sources * 2 actors = 4 compatible associations
        #expect(assocs.count == 4)

        let matched = router.match(compatibleAssociations: assocs)
        // 2 sources, each with 2 actors matched
        #expect(matched.count == 2)
        #expect(matched[s1.objectId.string]?.count == 2)
        #expect(matched[s2.objectId.string]?.count == 2)
    }

    @Test
    func testResolveSingleAssociation() {
        let router = makeRouter()
        let source = IoSource(valueType: "T", updateRate: 100)
        let actor = IoActor(valueType: "T", updateRate: 200)
        let sourceNode = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "sn",
            ioSources: [source], ioActors: []
        )
        let actorNode = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "an",
            ioSources: [], ioActors: [actor]
        )

        var map = IoAssociationPairs()
        let actors = MutableDictionaryBox<String, IoAssociationInfo>()
        let info = IoAssociationInfo(source, actor, 200)
        actors[actor.objectId.string] = info
        map[source.objectId.string] = actors

        let resolved = router.resolve(associationMap: map)
        #expect(resolved.count == 1)
        let resolvedActors = resolved[source.objectId.string]
        #expect(resolvedActors != nil)
        let resolvedInfo = resolvedActors![actor.objectId.string]
        #expect(resolvedInfo != nil)
        // Cumulated rate should be max(200, 200) = 200
        #expect(resolvedInfo!.2 == 200)
    }

    @Test
    func testResolveMultipleActorsPerSourceCumulatesRate() {
        let router = makeRouter()
        let source = IoSource(valueType: "T", updateRate: 100)
        let a1 = IoActor(valueType: "T", updateRate: 200)
        let a2 = IoActor(valueType: "T", updateRate: 500)
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: []
        )
        _ = node

        var map = IoAssociationPairs()
        let actors = MutableDictionaryBox<String, IoAssociationInfo>()
        actors[a1.objectId.string] = IoAssociationInfo(source, a1, 200)
        actors[a2.objectId.string] = IoAssociationInfo(source, a2, 500)
        map[source.objectId.string] = actors

        let resolved = router.resolve(associationMap: map)
        let resolvedActors = resolved[source.objectId.string]!
        // Both actors should have the cumulated rate = max(200, 500) = 500
        #expect(resolvedActors[a1.objectId.string]!.2 == 500)
        #expect(resolvedActors[a2.objectId.string]!.2 == 500)
    }

    @Test
    func testResolveEmptyMap() {
        let router = makeRouter()
        let map = IoAssociationPairs()
        let resolved = router.resolve(associationMap: map)
        #expect(resolved.isEmpty)
    }

    @Test
    func testBasicIoRouterDefaultRules() {
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
        let node = IoNode(
            coreType: .IoNode, objectType: IoNode.objectType,
            objectId: CoatyUUID(), name: "n",
            ioSources: [source], ioActors: [actor]
        )
        router.managedIoNodes[node.objectId.string] = node
        let assocs = router.getCompatibleAssociations()
        #expect(assocs.count == 1)
    }
}

// MARK: - Helpers

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
