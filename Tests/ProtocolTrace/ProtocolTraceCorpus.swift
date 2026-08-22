// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Versioned deterministic traces for the G2 protocol seam.
enum ProtocolTraceCorpus {
    static let eventFamilies = Set(TraceEventFamily.allCases)

    static func load() throws -> [ProtocolTrace] {
        let seeds = try loadFixtureSeeds()
        var traces = try TraceEventFamily.allCases.flatMap { family in
            let seed = try fixtureSeed(for: family, in: seeds)
            return [positiveTrace(for: family, seed: seed), malformedTrace(for: family, seed: seed)]
        }
        let associateSeed = try fixtureSeed(for: .associate, in: seeds)
        traces.append(contentsOf: [
            saturationTrace(seed: try fixtureSeed(for: .advertise, in: seeds)),
            duplicateTrace(seed: try fixtureSeed(for: .advertise, in: seeds)),
            staleCorrelationTrace(seed: try fixtureSeed(for: .return, in: seeds)),
            unsupportedTrace(seed: try fixtureSeed(for: .channel, in: seeds)),
            deadlineTrace(seed: try fixtureSeed(for: .discover, in: seeds)),
            payloadLimitTrace(seed: try fixtureSeed(for: .channel, in: seeds)),
            externalRouteTrace(seed: associateSeed),
            incompatibleExternalRouteTrace(seed: associateSeed),
        ])
        return traces
    }

    private struct FixtureSeedFile: Decodable {
        let schemaVersion: Int
        let families: [FixtureSeed]
    }

    private struct FixtureSeed: Decodable {
        let family: TraceEventFamily
        let valid: String
        let malformed: String
        let externalRoute: String
    }

    private enum CorpusError: Error {
        case missingFixture
        case invalidFixtureSchema
    }

    private static func loadFixtureSeeds() throws -> [TraceEventFamily: FixtureSeed] {
        guard let url = Bundle.module.url(forResource: "family-seeds", withExtension: "json") else {
            throw CorpusError.missingFixture
        }
        let document = try JSONDecoder().decode(FixtureSeedFile.self, from: Data(contentsOf: url))
        guard document.schemaVersion == 1, document.families.count == TraceEventFamily.allCases.count else {
            throw CorpusError.invalidFixtureSchema
        }
        return Dictionary(uniqueKeysWithValues: document.families.map { ($0.family, $0) })
    }

    private static func fixtureSeed(
        for family: TraceEventFamily,
        in seeds: [TraceEventFamily: FixtureSeed]
    ) throws -> FixtureSeed {
        guard let seed = seeds[family] else { throw CorpusError.missingFixture }
        return seed
    }

    private static func fixtureID(_ family: TraceEventFamily, _ variant: String) -> String {
        "Tests/ProtocolTrace/Fixtures/family-seeds.json#\(family.rawValue).\(variant)"
    }

    private static func positiveTrace(for family: TraceEventFamily, seed: FixtureSeed) -> ProtocolTrace {
        let (direction, operation, objectID, correlationID, route, priorState, nextState) = positiveShape(for: family)
        let fixtureVariant = family == .associate ? "externalRoute" : "valid"
        let input = TraceInput(
            family: family,
            direction: direction,
            fixtureID: fixtureID(family, fixtureVariant),
            fixturePayload: family == .associate ? seed.externalRoute : seed.valid,
            objectID: objectID,
            correlationID: correlationID,
            associatingRoute: route,
            routeClassification: family == .associate ? .external : nil,
            // The pinned CoatyJS external fixture omits the optional wire flag;
            // binding classification is carried separately above.
            isExternalRoute: nil
        )
        let step = TraceStep(
            sequence: 1,
            timeMilliseconds: 100,
            priorState: priorState,
            capabilities: TraceCapabilities(),
            limits: .default,
            input: input,
            localOperation: operation,
            expected: TraceObservation(
                actions: [TraceAction(
                    kind: operation == .publishOutbound ? "publish" : "deliver",
                    family: family,
                    correlationID: correlationID
                )],
                rejection: nil,
                nextState: nextState
            )
        )
        return ProtocolTrace(
            id: "positive-\(family.rawValue)",
            description: "Accepted \(family.rawValue) trace loaded from the maintained fixture seed",
            initialState: priorState,
            steps: [step]
        )
    }

    private static func malformedTrace(for family: TraceEventFamily, seed: FixtureSeed) -> ProtocolTrace {
        let state = TraceState()
        let input = TraceInput(
            family: family,
            direction: .inbound,
            fixtureID: fixtureID(family, "malformed"),
            fixturePayload: seed.malformed
        )
        let step = TraceStep(
            sequence: 1,
            timeMilliseconds: 100,
            priorState: state,
            capabilities: TraceCapabilities(),
            limits: .default,
            input: input,
            localOperation: .processInbound,
            expected: TraceObservation(
                actions: [],
                rejection: TraceRejection(code: .malformed, reason: "fixture is marked malformed"),
                nextState: state
            )
        )
        return ProtocolTrace(
            id: "malformed-\(family.rawValue)",
            description: "Malformed \(family.rawValue) fixture is rejected without state mutation",
            initialState: state,
            steps: [step]
        )
    }

    private static func positiveShape(
        for family: TraceEventFamily
    ) -> (
        TraceDirection,
        TraceLocalOperation,
        String?,
        String?,
        String?,
        TraceState,
        TraceState
    ) {
        switch family {
        case .advertise:
            return (.inbound, .processInbound, "object-001", nil, nil, TraceState(), TraceState(activeObjectIDs: ["object-001"], generation: 1))
        case .deadvertise:
            return (.inbound, .processInbound, "object-001", nil, nil, TraceState(activeObjectIDs: ["object-001"], generation: 1), TraceState(generation: 2))
        case .associate:
            return (.inbound, .processInbound, "route-001", nil, "external/wire-compat-v1/io-external-1", TraceState(), TraceState(associationIDs: ["route-001"], generation: 1))
        case .discover, .query, .update, .call:
            return (.outbound, .publishOutbound, nil, "correlation-001", nil, TraceState(), TraceState(pendingCorrelationIDs: ["correlation-001"], generation: 1))
        case .resolve, .retrieve, .complete, .return:
            return (.inbound, .processInbound, nil, "correlation-001", nil, TraceState(pendingCorrelationIDs: ["correlation-001"], generation: 1), TraceState(generation: 2))
        case .channel, .ioValue:
            return (.inbound, .processInbound, nil, nil, nil, TraceState(), TraceState(generation: 1))
        }
    }

    private static func saturationTrace(seed: FixtureSeed) -> ProtocolTrace {
        let state = TraceState(activeObjectIDs: ["object-001"], generation: 1)
        let input = TraceInput(
            family: .advertise,
            direction: .inbound,
            fixtureID: fixtureID(.advertise, "valid"),
            fixturePayload: seed.valid,
            objectID: "object-002"
        )
        return singleStep(
            id: "negative-saturation",
            description: "Exact object-table exhaustion has no partial mutation",
            state: state,
            input: input,
            limits: TraceLimits(maximumPayloadBytes: 512, maximumObjects: 1, maximumPendingCorrelations: 4),
            expected: rejected(.saturated, "object table is at capacity", state: state)
        )
    }

    private static func duplicateTrace(seed: FixtureSeed) -> ProtocolTrace {
        let state = TraceState(activeObjectIDs: ["object-001"], generation: 1)
        let input = TraceInput(
            family: .advertise,
            direction: .inbound,
            fixtureID: fixtureID(.advertise, "valid"),
            fixturePayload: seed.valid,
            objectID: "object-001",
            duplicate: true
        )
        return singleStep(
            id: "negative-duplicate",
            description: "Duplicate registration is rejected",
            state: state,
            input: input,
            expected: rejected(.duplicate, "object is already active", state: state)
        )
    }

    private static func staleCorrelationTrace(seed: FixtureSeed) -> ProtocolTrace {
        let state = TraceState()
        let input = TraceInput(
            family: .return,
            direction: .inbound,
            fixtureID: fixtureID(.return, "valid"),
            fixturePayload: seed.valid,
            correlationID: "stale-correlation"
        )
        return singleStep(
            id: "negative-stale-correlation",
            description: "A stale response token cannot mutate state",
            state: state,
            input: input,
            expected: rejected(.correlationMismatch, "response correlation is not pending", state: state)
        )
    }

    private static func unsupportedTrace(seed: FixtureSeed) -> ProtocolTrace {
        let state = TraceState()
        let input = TraceInput(
            family: .channel,
            direction: .inbound,
            fixtureID: fixtureID(.channel, "valid"),
            fixturePayload: seed.valid
        )
        let capabilities = TraceCapabilities(supportedFamilies: TraceEventFamily.allCases.filter { $0 != .channel })
        return singleStep(
            id: "negative-unsupported",
            description: "An unsupported family is rejected explicitly",
            state: state,
            input: input,
            capabilities: capabilities,
            expected: rejected(.unsupported, "family is outside the runtime capability set", state: state)
        )
    }

    private static func deadlineTrace(seed: FixtureSeed) -> ProtocolTrace {
        let state = TraceState()
        let input = TraceInput(
            family: .discover,
            direction: .outbound,
            fixtureID: fixtureID(.discover, "valid"),
            fixturePayload: seed.valid,
            correlationID: "expired-correlation",
            deadlineExpired: true
        )
        return singleStep(
            id: "negative-deadline",
            description: "A deadline rejection does not retain a pending request",
            state: state,
            timeMilliseconds: 5_000,
            input: input,
            operation: .publishOutbound,
            expected: rejected(.deadlineExpired, "operation deadline has elapsed", state: state)
        )
    }

    private static func payloadLimitTrace(seed: FixtureSeed) -> ProtocolTrace {
        let state = TraceState()
        let input = TraceInput(
            family: .channel,
            direction: .inbound,
            fixtureID: fixtureID(.channel, "valid+padding-513"),
            fixturePayload: seed.valid + String(repeating: " ", count: 513)
        )
        return singleStep(
            id: "negative-payload-limit",
            description: "Payload limit is distinct from state capacity",
            state: state,
            input: input,
            expected: rejected(.payloadTooLarge, "payload exceeds bounded trace workspace", state: state)
        )
    }

    private static func externalRouteTrace(seed: FixtureSeed) -> ProtocolTrace {
        let state = TraceState()
        let input = TraceInput(
            family: .associate,
            direction: .inbound,
            fixtureID: fixtureID(.associate, "externalRoute"),
            fixturePayload: seed.externalRoute,
            objectID: "external-route-001",
            associatingRoute: "external/wire-compat-v1/io-external-1",
            routeClassification: .external,
            isExternalRoute: nil
        )
        return singleStep(
            id: "positive-external-route",
            description: "Typed Coaty IO association accepts a binding-classified external route",
            state: state,
            input: input,
            expected: TraceObservation(
                actions: [TraceAction(kind: "deliver", family: .associate)],
                rejection: nil,
                nextState: TraceState(associationIDs: ["external-route-001"], generation: 1)
            )
        )
    }

    private static func incompatibleExternalRouteTrace(seed: FixtureSeed) -> ProtocolTrace {
        let state = TraceState()
        let input = TraceInput(
            family: .associate,
            direction: .inbound,
            fixtureID: fixtureID(.associate, "externalRoute"),
            fixturePayload: String(seed.externalRoute.dropLast()) + ",\"isExternalRoute\":true}",
            objectID: "invalid-route-001",
            associatingRoute: "external/wire-compat-v1/io-external-1",
            routeClassification: .coaty,
            isExternalRoute: true
        )
        return singleStep(
            id: "negative-external-route",
            description: "An external-route flag cannot contradict binding classification",
            state: state,
            input: input,
            expected: rejected(.externalRouteMismatch, "external route flag does not match the binding route", state: state)
        )
    }

    private static func singleStep(
        id: String,
        description: String,
        state: TraceState,
        timeMilliseconds: UInt64 = 100,
        input: TraceInput,
        limits: TraceLimits = .default,
        capabilities: TraceCapabilities = TraceCapabilities(),
        operation: TraceLocalOperation = .processInbound,
        expected: TraceObservation
    ) -> ProtocolTrace {
        ProtocolTrace(
            id: id,
            description: description,
            initialState: state,
            steps: [TraceStep(
                sequence: 1,
                timeMilliseconds: timeMilliseconds,
                priorState: state,
                capabilities: capabilities,
                limits: limits,
                input: input,
                localOperation: operation,
                expected: expected
            )]
        )
    }

    private static func rejected(_ code: TraceRejectionCode, _ reason: String, state: TraceState) -> TraceObservation {
        TraceObservation(actions: [], rejection: TraceRejection(code: code, reason: reason), nextState: state)
    }
}
