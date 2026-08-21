// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The thirteen Coaty Core wire families carried by the trace contract.
///
/// `IoState` is deliberately absent: it is a local association signal and has
/// no MQTT event family. The source of truth for these codes is the existing
/// borrowed-wire family corpus in `WireBoundsTests`.
enum TraceEventFamily: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case advertise = "ADV"
    case deadvertise = "DAD"
    case channel = "CHN"
    case associate = "ASC"
    case ioValue = "IOV"
    case discover = "DSC"
    case resolve = "RSV"
    case query = "QRY"
    case retrieve = "RTV"
    case update = "UPD"
    case complete = "CPL"
    case call = "CLL"
    case `return` = "RTN"
}

enum TraceDirection: String, Codable, Equatable, Sendable {
    case inbound
    case outbound
}

enum TraceRouteClassification: String, Codable, Equatable, Sendable {
    case coaty
    case external
}

enum TraceLocalOperation: String, Codable, Equatable, Sendable {
    case processInbound
    case publishOutbound
}

enum TraceRejectionCode: String, Codable, Equatable, Sendable {
    case malformed
    case payloadTooLarge
    case unsupported
    case duplicate
    case saturated
    case deadlineExpired
    case correlationMismatch
    case externalRouteMismatch
}

struct TraceState: Codable, Equatable, Sendable {
    let activeObjectIDs: [String]
    let pendingCorrelationIDs: [String]
    let associationIDs: [String]
    let generation: Int

    init(
        activeObjectIDs: [String] = [],
        pendingCorrelationIDs: [String] = [],
        associationIDs: [String] = [],
        generation: Int = 0
    ) {
        self.activeObjectIDs = activeObjectIDs.sorted()
        self.pendingCorrelationIDs = pendingCorrelationIDs.sorted()
        self.associationIDs = associationIDs.sorted()
        self.generation = generation
    }
}

struct TraceCapabilities: Codable, Equatable, Sendable {
    let supportedFamilies: [TraceEventFamily]

    init(supportedFamilies: [TraceEventFamily] = TraceEventFamily.allCases) {
        self.supportedFamilies = supportedFamilies.sorted { $0.rawValue < $1.rawValue }
    }
}

struct TraceLimits: Codable, Equatable, Sendable {
    let maximumPayloadBytes: Int
    let maximumObjects: Int
    let maximumPendingCorrelations: Int

    static let `default` = TraceLimits(
        maximumPayloadBytes: 512,
        maximumObjects: 4,
        maximumPendingCorrelations: 4
    )
}

struct TraceInput: Codable, Equatable, Sendable {
    let family: TraceEventFamily
    let direction: TraceDirection
    let fixtureID: String
    let fixturePayload: String
    let payloadBytes: Int
    let objectID: String?
    let correlationID: String?
    let associatingRoute: String?
    let routeClassification: TraceRouteClassification?
    /// The raw optional wire field. Binding classification is independent.
    let isExternalRoute: Bool?
    let duplicate: Bool
    let malformed: Bool
    let deadlineExpired: Bool

    init(
        family: TraceEventFamily,
        direction: TraceDirection,
        fixtureID: String,
        fixturePayload: String,
        objectID: String? = nil,
        correlationID: String? = nil,
        associatingRoute: String? = nil,
        routeClassification: TraceRouteClassification? = nil,
        isExternalRoute: Bool? = nil,
        duplicate: Bool = false,
        malformed: Bool? = nil,
        deadlineExpired: Bool = false
    ) {
        self.family = family
        self.direction = direction
        self.fixtureID = fixtureID
        self.fixturePayload = fixturePayload
        self.payloadBytes = fixturePayload.utf8.count
        self.objectID = objectID
        self.correlationID = correlationID
        self.associatingRoute = associatingRoute
        self.routeClassification = routeClassification
        self.isExternalRoute = isExternalRoute
        self.duplicate = duplicate
        self.malformed = malformed ?? !Self.isValidJSON(fixturePayload)
        self.deadlineExpired = deadlineExpired
    }

    private static func isValidJSON(_ payload: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(payload.utf8), options: [.fragmentsAllowed])) != nil
    }
}

struct TraceAction: Codable, Equatable, Sendable {
    let kind: String
    let family: TraceEventFamily
    let correlationID: String?

    init(kind: String, family: TraceEventFamily, correlationID: String? = nil) {
        self.kind = kind
        self.family = family
        self.correlationID = correlationID
    }
}

struct TraceRejection: Codable, Equatable, Sendable {
    let code: TraceRejectionCode
    let reason: String
}

struct TraceObservation: Codable, Equatable, Sendable {
    let actions: [TraceAction]
    let rejection: TraceRejection?
    let nextState: TraceState
}

struct TraceStep: Codable, Equatable, Sendable {
    let sequence: Int
    let timeMilliseconds: UInt64
    let priorState: TraceState
    let capabilities: TraceCapabilities
    let limits: TraceLimits
    let input: TraceInput
    let localOperation: TraceLocalOperation
    let expected: TraceObservation
}

struct ProtocolTrace: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let id: String
    let description: String
    let initialState: TraceState
    let steps: [TraceStep]

    init(id: String, description: String, initialState: TraceState, steps: [TraceStep]) {
        self.schemaVersion = Self.schemaVersion
        self.id = id
        self.description = description
        self.initialState = initialState
        self.steps = steps
    }
}

struct TraceRun: Codable, Equatable, Sendable {
    let traceID: String
    let observations: [TraceObservation]
}

enum TraceReplayError: Error, Equatable, Sendable {
    case schemaVersion(Int)
    case stateMismatch(traceID: String, sequence: Int)
    case expectedMismatch(traceID: String, sequence: Int)
    case staticCapacityExceeded(traceID: String, sequence: Int)
}

protocol TraceReplayAdapter: Sendable {
    func replay(_ trace: ProtocolTrace) throws -> TraceRun
}

/// Shared contract replay used by both profile adapters. The adapters differ
/// only in their storage envelope; protocol decisions are centralized here.
struct HostTraceReplayAdapter: TraceReplayAdapter {
    func replay(_ trace: ProtocolTrace) throws -> TraceRun {
        guard trace.schemaVersion == ProtocolTrace.schemaVersion else {
            throw TraceReplayError.schemaVersion(trace.schemaVersion)
        }

        var state = trace.initialState
        var observations: [TraceObservation] = []
        for step in trace.steps {
            guard step.priorState == state else {
                throw TraceReplayError.stateMismatch(traceID: trace.id, sequence: step.sequence)
            }
            let observation = transition(state: state, step: step)
            guard observation == step.expected else {
                throw TraceReplayError.expectedMismatch(traceID: trace.id, sequence: step.sequence)
            }
            state = observation.nextState
            observations.append(observation)
        }
        return TraceRun(traceID: trace.id, observations: observations)
    }

    private func transition(state: TraceState, step: TraceStep) -> TraceObservation {
        let input = step.input
        if input.payloadBytes > step.limits.maximumPayloadBytes {
            return rejected(state: state, code: .payloadTooLarge, reason: "payload exceeds bounded trace workspace")
        }
        if input.malformed {
            return rejected(state: state, code: .malformed, reason: "fixture is marked malformed")
        }
        if input.deadlineExpired {
            return rejected(state: state, code: .deadlineExpired, reason: "operation deadline has elapsed")
        }
        if !step.capabilities.supportedFamilies.contains(input.family) {
            return rejected(state: state, code: .unsupported, reason: "family is outside the runtime capability set")
        }

        switch input.family {
        case .advertise:
            guard let objectID = input.objectID else {
                return rejected(state: state, code: .malformed, reason: "advertise requires an object identifier")
            }
            if state.activeObjectIDs.contains(objectID) || input.duplicate {
                return rejected(state: state, code: .duplicate, reason: "object is already active")
            }
            guard state.activeObjectIDs.count < step.limits.maximumObjects else {
                return rejected(state: state, code: .saturated, reason: "object table is at capacity")
            }
            let next = TraceState(
                activeObjectIDs: state.activeObjectIDs + [objectID],
                pendingCorrelationIDs: state.pendingCorrelationIDs,
                associationIDs: state.associationIDs,
                generation: state.generation + 1
            )
            return accepted(state: next, step: step)

        case .deadvertise:
            guard let objectID = input.objectID, state.activeObjectIDs.contains(objectID) else {
                return rejected(state: state, code: .malformed, reason: "deadvertise requires an active object")
            }
            let next = TraceState(
                activeObjectIDs: state.activeObjectIDs.filter { $0 != objectID },
                pendingCorrelationIDs: state.pendingCorrelationIDs,
                associationIDs: state.associationIDs,
                generation: state.generation + 1
            )
            return accepted(state: next, step: step)

        case .associate:
            guard let associationID = input.objectID, input.associatingRoute != nil, let classification = input.routeClassification else {
                return rejected(state: state, code: .malformed, reason: "associate requires a route identifier")
            }
            if let explicit = input.isExternalRoute, explicit != (classification == .external) {
                return rejected(state: state, code: .externalRouteMismatch, reason: "external route flag does not match the binding route")
            }
            if state.associationIDs.contains(associationID) || input.duplicate {
                return rejected(state: state, code: .duplicate, reason: "association is already active")
            }
            let next = TraceState(
                activeObjectIDs: state.activeObjectIDs,
                pendingCorrelationIDs: state.pendingCorrelationIDs,
                associationIDs: state.associationIDs + [associationID],
                generation: state.generation + 1
            )
            return accepted(state: next, step: step)

        case .discover, .query, .update, .call:
            guard let correlationID = input.correlationID else {
                return rejected(state: state, code: .malformed, reason: "request requires a correlation identifier")
            }
            if state.pendingCorrelationIDs.contains(correlationID) || input.duplicate {
                return rejected(state: state, code: .duplicate, reason: "correlation is already pending")
            }
            guard state.pendingCorrelationIDs.count < step.limits.maximumPendingCorrelations else {
                return rejected(state: state, code: .saturated, reason: "pending correlation table is at capacity")
            }
            let next = TraceState(
                activeObjectIDs: state.activeObjectIDs,
                pendingCorrelationIDs: state.pendingCorrelationIDs + [correlationID],
                associationIDs: state.associationIDs,
                generation: state.generation + 1
            )
            return accepted(state: next, step: step)

        case .resolve, .retrieve, .complete, .return:
            guard let correlationID = input.correlationID, state.pendingCorrelationIDs.contains(correlationID) else {
                return rejected(state: state, code: .correlationMismatch, reason: "response correlation is not pending")
            }
            let next = TraceState(
                activeObjectIDs: state.activeObjectIDs,
                pendingCorrelationIDs: state.pendingCorrelationIDs.filter { $0 != correlationID },
                associationIDs: state.associationIDs,
                generation: state.generation + 1
            )
            return accepted(state: next, step: step)

        case .channel, .ioValue:
            return accepted(state: state, step: step)
        }
    }

    private func accepted(state: TraceState, step: TraceStep) -> TraceObservation {
        TraceObservation(
            actions: [TraceAction(
                kind: step.localOperation == .publishOutbound ? "publish" : "deliver",
                family: step.input.family,
                correlationID: step.input.correlationID
            )],
            rejection: nil,
            nextState: state
        )
    }

    private func rejected(state: TraceState, code: TraceRejectionCode, reason: String) -> TraceObservation {
        TraceObservation(
            actions: [],
            rejection: TraceRejection(code: code, reason: reason),
            nextState: state
        )
    }

}

/// Static-profile replay implemented independently with four fixed slots per
/// finite state table. It is intentionally not an alias for the host adapter:
/// equality is evidence that two storage representations agree on the
/// contract before production promotion.
struct StaticTraceReplayAdapter: TraceReplayAdapter {
    func replay(_ trace: ProtocolTrace) throws -> TraceRun {
        guard trace.schemaVersion == ProtocolTrace.schemaVersion else {
            throw TraceReplayError.schemaVersion(trace.schemaVersion)
        }

        var state = trace.initialState
        var observations: [TraceObservation] = []
        for step in trace.steps {
            guard step.priorState == state else {
                throw TraceReplayError.stateMismatch(traceID: trace.id, sequence: step.sequence)
            }
            let observation = try apply(traceID: trace.id, state: state, step: step)
            guard observation == step.expected else {
                throw TraceReplayError.expectedMismatch(traceID: trace.id, sequence: step.sequence)
            }
            state = observation.nextState
            observations.append(observation)
        }
        return TraceRun(traceID: trace.id, observations: observations)
    }

    private struct FixedSlotTable {
        private var first: String?
        private var second: String?
        private var third: String?
        private var fourth: String?

        init?(values: [String]) {
            guard values.count <= 4, Set(values).count == values.count else { return nil }
            first = values.indices.contains(0) ? values[0] : nil
            second = values.indices.contains(1) ? values[1] : nil
            third = values.indices.contains(2) ? values[2] : nil
            fourth = values.indices.contains(3) ? values[3] : nil
        }

        var count: Int {
            (first == nil ? 0 : 1) + (second == nil ? 0 : 1) + (third == nil ? 0 : 1) + (fourth == nil ? 0 : 1)
        }

        var values: [String] {
            [first, second, third, fourth].compactMap { $0 }.sorted()
        }

        func contains(_ value: String) -> Bool {
            first == value || second == value || third == value || fourth == value
        }

        mutating func insert(_ value: String) -> Bool {
            guard !contains(value) else { return false }
            if first == nil { first = value; return true }
            if second == nil { second = value; return true }
            if third == nil { third = value; return true }
            if fourth == nil { fourth = value; return true }
            return false
        }

        mutating func remove(_ value: String) -> Bool {
            if first == value { first = nil; return true }
            if second == value { second = nil; return true }
            if third == value { third = nil; return true }
            if fourth == value { fourth = nil; return true }
            return false
        }
    }

    private func apply(traceID: String, state: TraceState, step: TraceStep) throws -> TraceObservation {
        let input = step.input
        if input.payloadBytes > step.limits.maximumPayloadBytes {
            return rejected(state: state, code: .payloadTooLarge, reason: "payload exceeds bounded trace workspace")
        }
        if input.malformed {
            return rejected(state: state, code: .malformed, reason: "fixture is marked malformed")
        }
        if input.deadlineExpired {
            return rejected(state: state, code: .deadlineExpired, reason: "operation deadline has elapsed")
        }
        if !step.capabilities.supportedFamilies.contains(input.family) {
            return rejected(state: state, code: .unsupported, reason: "family is outside the runtime capability set")
        }

        guard var objects = FixedSlotTable(values: state.activeObjectIDs),
              var pending = FixedSlotTable(values: state.pendingCorrelationIDs),
              var associations = FixedSlotTable(values: state.associationIDs) else {
            throw TraceReplayError.staticCapacityExceeded(traceID: traceID, sequence: step.sequence)
        }
        var generation = state.generation

        switch input.family {
        case .advertise:
            guard let objectID = input.objectID else {
                return rejected(state: state, code: .malformed, reason: "advertise requires an object identifier")
            }
            guard !objects.contains(objectID), !input.duplicate else {
                return rejected(state: state, code: .duplicate, reason: "object is already active")
            }
            guard objects.count < step.limits.maximumObjects else {
                return rejected(state: state, code: .saturated, reason: "object table is at capacity")
            }
            guard objects.insert(objectID) else {
                return rejected(state: state, code: .saturated, reason: "static object table is at capacity")
            }
            generation += 1
        case .deadvertise:
            guard let objectID = input.objectID, objects.contains(objectID) else {
                return rejected(state: state, code: .malformed, reason: "deadvertise requires an active object")
            }
            _ = objects.remove(objectID)
            generation += 1
        case .associate:
            guard let associationID = input.objectID, input.associatingRoute != nil, let classification = input.routeClassification else {
                return rejected(state: state, code: .malformed, reason: "associate requires a route identifier")
            }
            if let explicit = input.isExternalRoute, explicit != (classification == .external) {
                return rejected(state: state, code: .externalRouteMismatch, reason: "external route flag does not match the binding route")
            }
            guard !associations.contains(associationID), !input.duplicate else {
                return rejected(state: state, code: .duplicate, reason: "association is already active")
            }
            guard associations.insert(associationID) else {
                return rejected(state: state, code: .saturated, reason: "static association table is at capacity")
            }
            generation += 1
        case .discover, .query, .update, .call:
            guard let correlationID = input.correlationID else {
                return rejected(state: state, code: .malformed, reason: "request requires a correlation identifier")
            }
            guard !pending.contains(correlationID), !input.duplicate else {
                return rejected(state: state, code: .duplicate, reason: "correlation is already pending")
            }
            guard pending.count < step.limits.maximumPendingCorrelations else {
                return rejected(state: state, code: .saturated, reason: "pending correlation table is at capacity")
            }
            guard pending.insert(correlationID) else {
                return rejected(state: state, code: .saturated, reason: "static pending table is at capacity")
            }
            generation += 1
        case .resolve, .retrieve, .complete, .return:
            guard let correlationID = input.correlationID, pending.contains(correlationID) else {
                return rejected(state: state, code: .correlationMismatch, reason: "response correlation is not pending")
            }
            _ = pending.remove(correlationID)
            generation += 1
        case .channel, .ioValue:
            break
        }

        return TraceObservation(
            actions: [TraceAction(
                kind: step.localOperation == .publishOutbound ? "publish" : "deliver",
                family: input.family,
                correlationID: input.correlationID
            )],
            rejection: nil,
            nextState: TraceState(
                activeObjectIDs: objects.values,
                pendingCorrelationIDs: pending.values,
                associationIDs: associations.values,
                generation: generation
            )
        )
    }

    private func rejected(state: TraceState, code: TraceRejectionCode, reason: String) -> TraceObservation {
        TraceObservation(
            actions: [],
            rejection: TraceRejection(code: code, reason: reason),
            nextState: state
        )
    }
}

enum ProtocolTraceCanonicalEncoding {
    static func data(for traces: [ProtocolTrace]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(traces)
    }
}
