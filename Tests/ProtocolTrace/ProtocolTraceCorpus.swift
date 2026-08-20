// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Versioned deterministic traces for the G2 protocol seam.
enum ProtocolTraceCorpus {
    static let all: [ProtocolTrace] = TraceEventFamily.allCases.flatMap { family in
        [positiveTrace(for: family), malformedTrace(for: family)]
    } + [
        saturationTrace,
        duplicateTrace,
        staleCorrelationTrace,
        unsupportedTrace,
        deadlineTrace,
        payloadLimitTrace,
    ]

    static let eventFamilies = Set(TraceEventFamily.allCases)

    private static let fixturePayloads: [TraceEventFamily: String] = [
        .advertise: #"{"object":{"objectId":"test"}}"#,
        .deadvertise: #"{"objectIds":["object-001"]}"#,
        .channel: #"{"object":{"id":"x"}}"#,
        .associate: #"{"ioSourceId":"source-001","ioActorId":"actor-001"}"#,
        .ioValue: #"{"payload":1}"#,
        .discover: #"{}"#,
        .resolve: #"{"object":{"id":"x"}}"#,
        .query: #"{}"#,
        .retrieve: #"{"object":{"id":"x"}}"#,
        .update: #"{"object":{"id":"x"}}"#,
        .complete: #"{}"#,
        .call: #"{"parameters":{"value":1},"filter":null}"#,
        .return: #"{}"#,
    ]

    private static func positiveTrace(for family: TraceEventFamily) -> ProtocolTrace {
        let (direction, operation, objectID, correlationID, priorState, nextState) = positiveShape(for: family)
        let input = TraceInput(
            family: family,
            direction: direction,
            fixturePayload: fixturePayloads[family]!,
            objectID: objectID,
            correlationID: correlationID
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
            description: "Accepted \(family.rawValue) trace from the pinned wire fixture seed",
            initialState: priorState,
            steps: [step]
        )
    }

    private static func malformedTrace(for family: TraceEventFamily) -> ProtocolTrace {
        let state = TraceState()
        let input = TraceInput(
            family: family,
            direction: .inbound,
            fixturePayload: fixturePayloads[family]!,
            malformed: true
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
            description: "Malformed \(family.rawValue) is rejected without state mutation",
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
        TraceState,
        TraceState
    ) {
        switch family {
        case .advertise:
            return (.inbound, .processInbound, "object-001", nil, TraceState(), TraceState(activeObjectIDs: ["object-001"], generation: 1))
        case .deadvertise:
            return (.inbound, .processInbound, "object-001", nil, TraceState(activeObjectIDs: ["object-001"], generation: 1), TraceState(generation: 2))
        case .associate:
            return (.inbound, .processInbound, "route-001", nil, TraceState(), TraceState(associationIDs: ["route-001"], generation: 1))
        case .discover, .query, .update, .call:
            return (.outbound, .publishOutbound, nil, "correlation-001", TraceState(), TraceState(pendingCorrelationIDs: ["correlation-001"], generation: 1))
        case .resolve, .retrieve, .complete, .return:
            return (.inbound, .processInbound, nil, "correlation-001", TraceState(pendingCorrelationIDs: ["correlation-001"], generation: 1), TraceState(generation: 2))
        case .channel, .ioValue:
            return (.inbound, .processInbound, nil, nil, TraceState(), TraceState())
        }
    }

    private static let saturationTrace: ProtocolTrace = {
        let state = TraceState(activeObjectIDs: ["object-001"])
        let input = TraceInput(
            family: .advertise,
            direction: .inbound,
            fixturePayload: fixturePayloads[.advertise]!,
            objectID: "object-002"
        )
        let step = TraceStep(
            sequence: 1,
            timeMilliseconds: 100,
            priorState: state,
            capabilities: TraceCapabilities(),
            limits: TraceLimits(maximumPayloadBytes: 512, maximumObjects: 1, maximumPendingCorrelations: 4),
            input: input,
            localOperation: .processInbound,
            expected: rejected(.saturated, "object table is at capacity", state: state)
        )
        return ProtocolTrace(id: "negative-saturation", description: "Exact object-table exhaustion has no partial mutation", initialState: state, steps: [step])
    }()

    private static let duplicateTrace: ProtocolTrace = {
        let state = TraceState(activeObjectIDs: ["object-001"])
        let input = TraceInput(
            family: .advertise,
            direction: .inbound,
            fixturePayload: fixturePayloads[.advertise]!,
            objectID: "object-001",
            duplicate: true
        )
        let step = TraceStep(
            sequence: 1,
            timeMilliseconds: 100,
            priorState: state,
            capabilities: TraceCapabilities(),
            limits: .default,
            input: input,
            localOperation: .processInbound,
            expected: rejected(.duplicate, "object is already active", state: state)
        )
        return ProtocolTrace(id: "negative-duplicate", description: "Duplicate registration is rejected", initialState: state, steps: [step])
    }()

    private static let staleCorrelationTrace: ProtocolTrace = {
        let state = TraceState()
        let input = TraceInput(
            family: .return,
            direction: .inbound,
            fixturePayload: fixturePayloads[.return]!,
            correlationID: "stale-correlation"
        )
        let step = TraceStep(
            sequence: 1,
            timeMilliseconds: 100,
            priorState: state,
            capabilities: TraceCapabilities(),
            limits: .default,
            input: input,
            localOperation: .processInbound,
            expected: rejected(.correlationMismatch, "response correlation is not pending", state: state)
        )
        return ProtocolTrace(id: "negative-stale-correlation", description: "A stale response token cannot mutate state", initialState: state, steps: [step])
    }()

    private static let unsupportedTrace: ProtocolTrace = {
        let state = TraceState()
        let input = TraceInput(
            family: .channel,
            direction: .inbound,
            fixturePayload: fixturePayloads[.channel]!
        )
        let capabilities = TraceCapabilities(supportedFamilies: TraceEventFamily.allCases.filter { $0 != .channel })
        let step = TraceStep(
            sequence: 1,
            timeMilliseconds: 100,
            priorState: state,
            capabilities: capabilities,
            limits: .default,
            input: input,
            localOperation: .processInbound,
            expected: rejected(.unsupported, "family is outside the runtime capability set", state: state)
        )
        return ProtocolTrace(id: "negative-unsupported", description: "An unsupported family is rejected explicitly", initialState: state, steps: [step])
    }()

    private static let deadlineTrace: ProtocolTrace = {
        let state = TraceState()
        let input = TraceInput(
            family: .discover,
            direction: .outbound,
            fixturePayload: fixturePayloads[.discover]!,
            correlationID: "expired-correlation",
            deadlineExpired: true
        )
        let step = TraceStep(
            sequence: 1,
            timeMilliseconds: 5_000,
            priorState: state,
            capabilities: TraceCapabilities(),
            limits: .default,
            input: input,
            localOperation: .publishOutbound,
            expected: rejected(.deadlineExpired, "operation deadline has elapsed", state: state)
        )
        return ProtocolTrace(id: "negative-deadline", description: "A deadline rejection does not retain a pending request", initialState: state, steps: [step])
    }()

    private static let payloadLimitTrace: ProtocolTrace = {
        let state = TraceState()
        let input = TraceInput(
            family: .channel,
            direction: .inbound,
            fixturePayload: String(repeating: "x", count: 513)
        )
        let step = TraceStep(
            sequence: 1,
            timeMilliseconds: 100,
            priorState: state,
            capabilities: TraceCapabilities(),
            limits: .default,
            input: input,
            localOperation: .processInbound,
            expected: rejected(.payloadTooLarge, "payload exceeds bounded trace workspace", state: state)
        )
        return ProtocolTrace(id: "negative-payload-limit", description: "Payload limit is distinct from state capacity", initialState: state, steps: [step])
    }()

    private static func rejected(_ code: TraceRejectionCode, _ reason: String, state: TraceState) -> TraceObservation {
        TraceObservation(actions: [], rejection: TraceRejection(code: code, reason: reason), nextState: state)
    }
}
