// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyProtocol
import AxolotyWire

/// The thirteen Coaty Core wire families carried by the trace contract.
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
enum TraceDirection: String, Codable, Equatable, Sendable { case inbound, outbound }
enum TraceRouteClassification: String, Codable, Equatable, Sendable { case coaty, external }
enum TraceLocalOperation: String, Codable, Equatable, Sendable { case processInbound, publishOutbound }
enum TraceRejectionCode: String, Codable, Equatable, Sendable {
    case malformed, payloadTooLarge, unsupported, duplicate, saturated, deadlineExpired, correlationMismatch, externalRouteMismatch
}

struct TraceState: Codable, Equatable, Sendable {
    let activeObjectIDs: [String]
    let pendingCorrelationIDs: [String]
    let associationIDs: [String]
    let generation: Int
    init(activeObjectIDs: [String] = [], pendingCorrelationIDs: [String] = [], associationIDs: [String] = [], generation: Int = 0) {
        self.activeObjectIDs = activeObjectIDs.sorted()
        self.pendingCorrelationIDs = pendingCorrelationIDs.sorted()
        self.associationIDs = associationIDs.sorted()
        self.generation = generation
    }
}
struct TraceCapabilities: Codable, Equatable, Sendable {
    let supportedFamilies: [TraceEventFamily]
    init(supportedFamilies: [TraceEventFamily] = TraceEventFamily.allCases) { self.supportedFamilies = supportedFamilies.sorted { $0.rawValue < $1.rawValue } }
}
struct TraceLimits: Codable, Equatable, Sendable {
    let maximumPayloadBytes: Int
    let maximumObjects: Int
    let maximumPendingCorrelations: Int
    static let `default` = TraceLimits(maximumPayloadBytes: 512, maximumObjects: 4, maximumPendingCorrelations: 4)
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
    let isExternalRoute: Bool?
    let duplicate: Bool
    let malformed: Bool
    let deadlineExpired: Bool
    init(family: TraceEventFamily, direction: TraceDirection, fixtureID: String, fixturePayload: String, objectID: String? = nil, correlationID: String? = nil, associatingRoute: String? = nil, routeClassification: TraceRouteClassification? = nil, isExternalRoute: Bool? = nil, duplicate: Bool = false, malformed: Bool? = nil, deadlineExpired: Bool = false) {
        self.family = family; self.direction = direction; self.fixtureID = fixtureID; self.fixturePayload = fixturePayload
        self.payloadBytes = fixturePayload.utf8.count; self.objectID = objectID; self.correlationID = correlationID
        self.associatingRoute = associatingRoute; self.routeClassification = routeClassification; self.isExternalRoute = isExternalRoute
        self.duplicate = duplicate; self.malformed = malformed ?? ((try? JSONSerialization.jsonObject(with: Data(fixturePayload.utf8), options: [.fragmentsAllowed])) == nil); self.deadlineExpired = deadlineExpired
    }
}
struct TraceAction: Codable, Equatable, Sendable {
    let kind: String; let family: TraceEventFamily; let correlationID: String?
    init(kind: String, family: TraceEventFamily, correlationID: String? = nil) { self.kind = kind; self.family = family; self.correlationID = correlationID }
}
struct TraceRejection: Codable, Equatable, Sendable { let code: TraceRejectionCode; let reason: String }
struct TraceObservation: Codable, Equatable, Sendable { let actions: [TraceAction]; let rejection: TraceRejection?; let nextState: TraceState }
struct TraceStep: Codable, Equatable, Sendable {
    let sequence: Int; let timeMilliseconds: UInt64; let priorState: TraceState; let capabilities: TraceCapabilities; let limits: TraceLimits; let input: TraceInput; let localOperation: TraceLocalOperation; let expected: TraceObservation
}
struct ProtocolTrace: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    let schemaVersion: Int; let id: String; let description: String; let initialState: TraceState; let steps: [TraceStep]
    init(id: String, description: String, initialState: TraceState, steps: [TraceStep]) { self.schemaVersion = Self.schemaVersion; self.id = id; self.description = description; self.initialState = initialState; self.steps = steps }
}
struct TraceRun: Codable, Equatable, Sendable { let traceID: String; let observations: [TraceObservation] }
enum TraceReplayError: Error, Equatable, Sendable {
    case schemaVersion(Int); case stateMismatch(traceID: String, sequence: Int); case expectedMismatch(traceID: String, sequence: Int); case staticCapacityExceeded(traceID: String, sequence: Int)
}
protocol TraceReplayAdapter: Sendable { func replay(_ trace: ProtocolTrace) throws -> TraceRun }

struct HostTraceReplayAdapter: TraceReplayAdapter {
    func replay(_ trace: ProtocolTrace) throws -> TraceRun {
        var replay = try SharedProtocolTraceReplay<64>(trace: trace)
        var sink = ReusableProtocolActionSink()
        return try replay.replay(trace, sink: &sink)
    }
}
struct StaticTraceReplayAdapter: TraceReplayAdapter {
    func replay(_ trace: ProtocolTrace) throws -> TraceRun {
        var replay = try SharedProtocolTraceReplay<16>(trace: trace)
        var sink = InlineProtocolActionSink<16>()
        return try replay.replay(trace, sink: &sink)
    }
}

private protocol TraceReplaySink: ~Copyable, ProtocolActionSink {
    var count: Int { get }
    subscript(index: Int) -> BorrowedProtocolAction? { get }
    mutating func removeAll()
}

extension InlineProtocolActionSink: TraceReplaySink {}
extension ReusableProtocolActionSink: TraceReplaySink {}

/// Both adapters differ only in processor storage/sink capacity; all
/// transitions enter the production processor Interface.
private struct SharedProtocolTraceReplay<let capacity: Int>: ~Copyable {
    private var processor: ProtocolProcessor<capacity>

    init(trace: ProtocolTrace) throws {
        guard let firstStep = trace.steps.first else {
            self.processor = ProtocolProcessor<capacity>()
            return
        }
        self.processor = ProtocolProcessor<capacity>(
            capabilities: try Self.capabilities(firstStep.capabilities.supportedFamilies),
            maximumPayloadBytes: firstStep.limits.maximumPayloadBytes,
            maximumObjects: firstStep.limits.maximumObjects,
            maximumPendingCorrelations: firstStep.limits.maximumPendingCorrelations
        )
    }

    mutating func replay<S: ~Copyable & TraceReplaySink>(_ trace: ProtocolTrace, sink: inout S) throws -> TraceRun {
        guard trace.schemaVersion == ProtocolTrace.schemaVersion else { throw TraceReplayError.schemaVersion(trace.schemaVersion) }
        var state = trace.initialState
        var observations: [TraceObservation] = []
        var labels = TraceLabels()
        var projection = ProtocolFixedStateSnapshot<capacity>()
        var seeded = false
        for step in trace.steps {
            guard step.priorState == state else { throw TraceReplayError.stateMismatch(traceID: trace.id, sequence: step.sequence) }
            labels.learn(state: state)
            labels.learn(input: step.input)
            if !seeded {
                // Materialize initial state once through the production
                // Interface; later steps exercise the same processor state.
                for objectID in state.activeObjectIDs {
                    try Self.seedObject(objectID, processor: &processor, sink: &sink, time: step.timeMilliseconds)
                    sink.removeAll()
                }
                if let correlationID = state.pendingCorrelationIDs.first {
                    let request = Self.requestSeed(for: trace.steps.first?.input.family ?? .resolve)
                    try Self.withBorrowedPayload(request.payload) { payload in
                        let operation = try ProtocolLocalOperation(
                            capability: request.capability,
                            sourceID: Self.identity("trace-requester"),
                            correlationID: Self.identity(correlationID),
                            payload: payload,
                            requestTimeoutMS: 5_000
                        )
                        _ = processor.processOutbound(
                            operation,
                            nowMS: UInt32(step.timeMilliseconds),
                            sink: &sink
                        )
                        sink.removeAll()
                    }
                }
                seeded = true
            }
            let outcome = try Self.process(step, processor: &processor, sink: &sink)
            processor.copyState(into: &projection)
            let generation = processor.state.generation
            let observation = Self.observation(for: outcome, step: step, projection: projection, generation: generation, sink: sink, labels: labels)
            guard observation == step.expected else { throw TraceReplayError.expectedMismatch(traceID: trace.id, sequence: step.sequence) }
            if observation.rejection == nil { state = observation.nextState }
            observations.append(observation)
            sink.removeAll()
        }
        return TraceRun(traceID: trace.id, observations: observations)
    }

    private static func seedObject<S: ~Copyable & ProtocolActionSink>(_ name: String, processor: inout ProtocolProcessor<capacity>, sink: inout S, time: UInt64) throws {
        let object = Self.identity(name)
        let topic = "coaty/3/trace/ADV/\(Self.uuidText(object))"
        // Seed through the same validated Advertise path as the trace step.
        // An empty object is syntactically JSON but is not an accepted
        // AdvertiseWireData value, which would leave a following Deadvertise
        // trace without the object it claims to remove.
        let payload = "{\"object\":{\"objectId\":\"\(Self.uuidText(object))\",\"coreType\":\"CoatyObject\",\"objectType\":\"trace.Object\",\"name\":\"\(name)\"}}"
        try Self.withBorrowed(topic: topic, payload: payload) { frame in
            _ = processor.processInbound(.profile(frame), nowMS: UInt32(time), sink: &sink)
        }
    }

    private static func process<S: ~Copyable & ProtocolActionSink>(_ step: TraceStep, processor: inout ProtocolProcessor<capacity>, sink: inout S) throws -> ProtocolProcessOutcome {
        let input = step.input
        let source = Self.identity(input.objectID ?? "trace-source")
        let capabilityValue = Self.capability(input.family)
        // Malformed payload traces must still carry a syntactically valid
        // response topic; otherwise frame construction fails before the
        // processor can record the intended payload rejection.
        let correlation = input.correlationID.map(Self.identity)
            ?? (capabilityValue.isOneWay ? nil : Self.identity("malformed-correlation"))
        let code = input.family.rawValue
        let correlationText = correlation.map(Self.uuidText)
        let topic = "coaty/3/trace/\(code)/\(Self.uuidText(source))" + (correlationText.map { "/\($0)" } ?? "")
        if input.direction == .outbound {
            return try Self.withBorrowedPayload(input.fixturePayload) { payload in
                let operation = try ProtocolLocalOperation(
                    capability: capabilityValue, sourceID: source, correlationID: correlation,
                    payload: payload,
                    requestTimeoutMS: input.deadlineExpired ? 0 : (correlation == nil ? nil : 5_000)
                )
                return processor.processOutbound(operation, nowMS: UInt32(step.timeMilliseconds), sink: &sink)
            }
        }
        return try Self.withBorrowed(topic: topic, payload: input.fixturePayload) { frame in
            let classifier = TraceClassifier(classification: input.routeClassification == .external ? .external : (input.routeClassification == .coaty ? .coaty : .coaty))
            return processor.processInbound(.profile(frame), nowMS: UInt32(step.timeMilliseconds), classifier: classifier, sink: &sink)
        }
    }

    private static func observation<S: ~Copyable & TraceReplaySink>(for outcome: ProtocolProcessOutcome, step: TraceStep, projection: borrowing ProtocolFixedStateSnapshot<capacity>, generation: UInt32, sink: borrowing S, labels: borrowing TraceLabels) -> TraceObservation {
        let nextState = Self.snapshot(projection, generation: generation, labels: labels)
        switch outcome {
        case .accepted:
            var actions: [TraceAction] = []
            for index in 0..<sink.count {
                guard let action = sink[index] else { continue }
                let kind: String
                let routingKey: ProtocolRoutingKey
                switch action {
                case .publish(let publication):
                    kind = "publish"
                    routingKey = publication.routingKey
                case .deliver(let delivery):
                    kind = "deliver"
                    routingKey = delivery.routingKey
                case .associationChanged(let transition):
                    kind = "deliver"
                    routingKey = transition.delivery.routingKey
                case .externalRouteActivated, .externalRouteDeactivated:
                    kind = "deliver"
                    continue
                }
                actions.append(TraceAction(
                    kind: kind,
                    family: Self.traceFamily(routingKey.capability),
                    correlationID: routingKey.correlationID.map { labels.correlationLabel(for: $0) ?? Self.uuidText($0) }
                ))
            }
            return TraceObservation(actions: actions, rejection: nil, nextState: nextState)
        case .ignored:
            return TraceObservation(actions: [], rejection: nil, nextState: nextState)
        case .rejected(let code):
            let traceCode: TraceRejectionCode = code == .capacityExceeded && step.input.payloadBytes > step.limits.maximumPayloadBytes ? .payloadTooLarge : Self.traceCode(code)
            return TraceObservation(actions: [], rejection: TraceRejection(code: traceCode, reason: Self.reason(traceCode)), nextState: nextState)
        }
    }

    private struct TraceClassifier: ProtocolRouteClassifier, Sendable {
        let classification: ProtocolRouteClassification
        func classify(_: ByteSlice) -> ProtocolRouteClassification { classification }
    }

    private static func withBorrowed<R>(topic: String, payload: String, _ body: (BorrowedProtocolFrame) throws -> R) throws -> R {
        let topicBytes = Array(topic.utf8); let payloadBytes = Array(payload.utf8)
        return try topicBytes.withUnsafeBufferPointer { topicBuffer in
            try payloadBytes.withUnsafeBufferPointer { payloadBuffer in
                let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
                return try body(try BorrowedProtocolFrame(topic: view, payload: ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)))
            }
        }
    }
    private static func withBorrowedPayload<R>(_ payload: String, _ body: (ByteSlice) throws -> R) throws -> R {
        let bytes = Array(payload.utf8)
        return try bytes.withUnsafeBufferPointer { try body(ByteSlice(bytes: $0.baseAddress!, length: $0.count)) }
    }
    private static func requestSeed(for responseFamily: TraceEventFamily) -> (capability: ProtocolCapability, payload: String) {
        switch responseFamily {
        case .resolve: return (.discover, "{}")
        case .retrieve: return (.query, "{}")
        case .complete: return (.update, "{\"object\":{\"id\":\"x\"}}")
        case .return: return (.call, "{\"parameters\":{\"value\":1},\"filter\":null}")
        default: return (.discover, "{}")
        }
    }
    private static func capability(_ family: TraceEventFamily) -> ProtocolCapability {
        switch family { case .advertise: return .advertise; case .deadvertise: return .deadvertise; case .channel: return .channel; case .associate: return .associate; case .ioValue: return .ioValue; case .discover: return .discover; case .resolve: return .resolve; case .query: return .query; case .retrieve: return .retrieve; case .update: return .update; case .complete: return .complete; case .call: return .call; case .return: return .returnEvent }
    }
    private static func traceFamily(_ capability: ProtocolCapability) -> TraceEventFamily {
        switch capability { case .advertise: return .advertise; case .deadvertise: return .deadvertise; case .channel: return .channel; case .associate: return .associate; case .ioValue: return .ioValue; case .discover: return .discover; case .resolve: return .resolve; case .query: return .query; case .retrieve: return .retrieve; case .update: return .update; case .complete: return .complete; case .call: return .call; case .returnEvent: return .return }
    }

    private static func capabilities(_ families: [TraceEventFamily]) throws -> ProtocolCapabilities {
        var rawValue: UInt16 = 0
        for family in families {
            rawValue |= UInt16(1) << UInt16(Self.capability(family).rawValue)
        }
        return try ProtocolCapabilities(rawValue: rawValue)
    }
    private static func identity(_ value: String) -> UUID16 {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let b0 = UInt8(truncatingIfNeeded: hash >> 24), b1 = UInt8(truncatingIfNeeded: hash >> 16), b2 = UInt8(truncatingIfNeeded: hash >> 8), b3 = UInt8(truncatingIfNeeded: hash)
        return UUID16(bytes: (b0,b1,b2,b3,0,0,0x40,0,0x80,0,0,0,0,0,0,1))
    }
    private static func uuidText(_ id: UUID16) -> String {
        let b = id.bytes
        return String(format: "%02x%02x%02x%02x-0000-4000-8000-000000000001", b.0,b.1,b.2,b.3)
    }

    private static func snapshot(_ state: borrowing ProtocolFixedStateSnapshot<capacity>, generation: UInt32, labels: borrowing TraceLabels) -> TraceState {
        TraceState(
            activeObjectIDs: (0..<state.activeObjectCount).compactMap { index in
                guard let id = state.activeObjectIDs[index] else { return nil }
                return labels.objectLabel(for: id) ?? Self.uuidText(id)
            },
            pendingCorrelationIDs: (0..<state.pendingCorrelationCount).compactMap { index in
                guard let id = state.pendingCorrelationIDs[index] else { return nil }
                return labels.correlationLabel(for: id) ?? Self.uuidText(id)
            },
            associationIDs: (0..<state.associationCount).compactMap { index in
                guard let id = state.associationSourceIDs[index] else { return nil }
                return labels.associationLabel(for: id) ?? Self.uuidText(id)
            },
            generation: Int(generation)
        )
    }

    private struct TraceLabels {
        var objects: [(UUID16, String)] = []
        var correlations: [(UUID16, String)] = []
        var associations: [(UUID16, String)] = []

        mutating func learn(state: TraceState) {
            for value in state.activeObjectIDs { objects.append((Self.identity(value), value)) }
            for value in state.pendingCorrelationIDs { correlations.append((Self.identity(value), value)) }
        }

        mutating func learn(input: TraceInput) {
            if let objectID = input.objectID { objects.append((Self.identity(objectID), objectID)) }
            if let correlationID = input.correlationID { correlations.append((Self.identity(correlationID), correlationID)) }
            guard input.family == .associate else { return }
            let bytes = Array(input.fixturePayload.utf8)
            bytes.withUnsafeBufferPointer { buffer in
                let reader = WireReader(bytes: buffer.baseAddress!, length: buffer.count)
                if let event = try? AssociateWireData(from: reader), let label = input.objectID {
                    associations.append((event.ioSourceId, label))
                }
            }
        }

        func objectLabel(for id: UUID16) -> String? { objects.last { $0.0 == id }?.1 }
        func correlationLabel(for id: UUID16) -> String? { correlations.last { $0.0 == id }?.1 }
        func associationLabel(for id: UUID16) -> String? { associations.last { $0.0 == id }?.1 }

        private static func identity(_ value: String) -> UUID16 {
            var hash: UInt32 = 2_166_136_261
            for byte in value.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
            let b0 = UInt8(truncatingIfNeeded: hash >> 24), b1 = UInt8(truncatingIfNeeded: hash >> 16), b2 = UInt8(truncatingIfNeeded: hash >> 8), b3 = UInt8(truncatingIfNeeded: hash)
            return UUID16(bytes: (b0,b1,b2,b3,0,0,0x40,0,0x80,0,0,0,0,0,0,1))
        }
    }
    private static func traceCode(_ code: ProtocolError.Code) -> TraceRejectionCode {
        switch code { case .malformedFrame, .malformedPayload, .invalidCorrelation: return .malformed; case .unsupportedCapability: return .unsupported; case .capacityExceeded: return .saturated; case .duplicate: return .duplicate; case .deadlineExpired: return .deadlineExpired; case .correlationMismatch: return .correlationMismatch; case .externalRouteMismatch: return .externalRouteMismatch; case .borrowedValueEscaped: return .malformed }
    }
    private static func reason(_ code: TraceRejectionCode) -> String {
        switch code { case .payloadTooLarge: return "payload exceeds bounded trace workspace"; case .malformed: return "fixture is marked malformed"; case .deadlineExpired: return "operation deadline has elapsed"; case .unsupported: return "family is outside the runtime capability set"; case .duplicate: return "object is already active"; case .saturated: return "object table is at capacity"; case .correlationMismatch: return "response correlation is not pending"; case .externalRouteMismatch: return "external route flag does not match the binding route" }
    }
}

enum ProtocolTraceCanonicalEncoding {
    static func data(for traces: [ProtocolTrace]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(traces)
    }
}
