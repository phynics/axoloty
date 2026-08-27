// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@_spi(AxolotyRuntimeAdapter) import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyStaticRuntime
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
protocol TraceReplayAdapter: Sendable { func replay(_ trace: ProtocolTrace) async throws -> TraceRun }

struct HostTraceReplayAdapter: TraceReplayAdapter {
    func replay(_ trace: ProtocolTrace) async throws -> TraceRun {
        try await HostRuntimeTraceReplay(trace: trace).replay()
    }
}
struct StaticTraceReplayAdapter: TraceReplayAdapter {
    func replay(_ trace: ProtocolTrace) async throws -> TraceRun {
        var replay = try SharedProtocolTraceReplay<16>(trace: trace)
        var sink = InlineProtocolActionSink<16>()
        var verifier: StaticTraceVerifier<16>? = try StaticTraceVerifier<16>(trace: trace)
        return try replay.replay(trace, sink: &sink, staticVerifier: &verifier)
    }
}

private final class HostTraceTransport: AxolotyRuntimeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var classification: ProtocolRouteClassification = .coaty
    private var effects: [RuntimeTransportEffect] = []

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {}
    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async {}
    func installSubscriptions(namespace: String) async throws {}
    func removeSubscriptions(namespace: String) async throws {}
    func stop() async {}

    func perform(_ effect: RuntimeTransportEffect, namespace: String) async throws {
        lock.lock(); defer { lock.unlock() }
        effects.append(effect)
    }

    func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification {
        lock.lock(); defer { lock.unlock() }
        return classification
    }

    func setClassification(_ value: ProtocolRouteClassification) {
        lock.lock(); defer { lock.unlock() }
        classification = value
    }
}

private struct HostRuntimeTraceReplay {
    private let trace: ProtocolTrace
    private let runtime: AxolotyRuntime
    private let transport: HostTraceTransport

    init(trace: ProtocolTrace) throws {
        self.trace = trace
        let transport = HostTraceTransport()
        self.transport = transport
        let sourceID = UUID16.zero
        let firstLimits = trace.steps.first?.limits ?? .default
        let capacities = try RuntimeCapacities(
            protocolMaximumPayloadBytes: firstLimits.maximumPayloadBytes,
            protocolMaximumObjects: firstLimits.maximumObjects,
            protocolMaximumPendingCorrelations: firstLimits.maximumPendingCorrelations
        )
        var definition = try RuntimeDefinition(
            namespace: "trace",
            sourceID: sourceID,
            capacities: capacities
        )
        let sealedDefinition = try definition.seal()
        self.runtime = AxolotyRuntime(definition: sealedDefinition, transport: transport)
    }

    func replay() async throws -> TraceRun {
        guard trace.schemaVersion == ProtocolTrace.schemaVersion else {
            throw TraceReplayError.schemaVersion(trace.schemaVersion)
        }
        try await runtime.start()
        _ = await runtime.conformanceObservation()
        var state = trace.initialState
        var labels = TraceLabels()
        var observations: [TraceObservation] = []
        if let firstStep = trace.steps.first {
            try await seed(state: state, time: firstStep.timeMilliseconds, family: firstStep.input.family)
            _ = await runtime.conformanceObservation()
        }
        for step in trace.steps {
            guard step.priorState == state else {
                await runtime.close()
                throw TraceReplayError.stateMismatch(traceID: trace.id, sequence: step.sequence)
            }
            labels.learn(state: state)
            labels.learn(input: step.input)
            let (receipt, projection) = try await apply(step)
            let observation = Self.observation(
                receipt: receipt,
                projection: projection,
                step: step,
                labels: labels
            )
            guard observation == step.expected else {
                await runtime.close()
                throw TraceReplayError.expectedMismatch(traceID: trace.id, sequence: step.sequence)
            }
            if observation.rejection == nil { state = observation.nextState }
            observations.append(observation)
        }
        await runtime.close()
        return TraceRun(traceID: trace.id, observations: observations)
    }

    private func seed(state: TraceState, time: UInt64, family: TraceEventFamily) async throws {
        for objectID in state.activeObjectIDs {
            let object = Self.identity(objectID)
            let topic = "coaty/3/trace/ADV/\(Self.uuidText(object))"
            let payload = "{\"object\":{\"objectId\":\"\(Self.uuidText(object))\",\"coreType\":\"CoatyObject\",\"objectType\":\"trace.Object\",\"name\":\"\(objectID)\"}}"
            _ = await runtime.receive(.profile(topic: topic, payload: Array(payload.utf8), nowMS: UInt32(time)))
        }
        if let correlationID = state.pendingCorrelationIDs.first {
            let correlation = Self.identity(correlationID)
            let payload: [UInt8]
            switch family {
            case .resolve: payload = Array("{}".utf8)
            case .retrieve: payload = Array("{}".utf8)
            case .complete: payload = Array("{\"object\":{\"id\":\"x\"}}".utf8)
            case .return: payload = Array("{\"parameters\":{\"value\":1},\"filter\":null}".utf8)
            default: payload = Array("{}".utf8)
            }
            let request: RuntimeRequest = family == .return
                ? .call(correlationID: correlation, payload: payload, timeoutMS: 5_000)
                : family == .complete
                    ? .update(correlationID: correlation, payload: payload, timeoutMS: 5_000)
                    : family == .retrieve
                        ? .query(correlationID: correlation, payload: payload, timeoutMS: 5_000)
                        : .discover(correlationID: correlation, payload: payload, timeoutMS: 5_000)
            _ = await runtime.request(request, nowMS: UInt32(time))
        }
    }

    private func apply(_ step: TraceStep) async throws -> (RuntimeReceipt, RuntimeConformanceObservation) {
        let input = step.input
        let source = Self.identity(input.objectID ?? "trace-source")
        let correlation = input.correlationID.map(Self.identity)
            ?? (SharedProtocolTraceReplay<64>.capability(input.family).isOneWay ? nil : Self.identity("malformed-correlation"))
        transport.setClassification(input.routeClassification == .external ? .external : .coaty)
        let receipt: RuntimeReceipt
        if input.direction == .outbound {
            switch input.family {
            case .advertise: receipt = await runtime.publish(.advertise(Array(input.fixturePayload.utf8)), nowMS: UInt32(step.timeMilliseconds))
            case .deadvertise: receipt = await runtime.publish(.deadvertise(Array(input.fixturePayload.utf8)), nowMS: UInt32(step.timeMilliseconds))
            case .channel: receipt = await runtime.publish(.channel(identifier: "trace", payload: Array(input.fixturePayload.utf8)), nowMS: UInt32(step.timeMilliseconds))
            case .associate: receipt = await runtime.publish(.associate(Array(input.fixturePayload.utf8)), nowMS: UInt32(step.timeMilliseconds))
            case .ioValue: receipt = await runtime.publish(.ioValue(Array(input.fixturePayload.utf8)), nowMS: UInt32(step.timeMilliseconds))
            case .discover: receipt = await runtime.request(.discover(correlationID: correlation!, payload: Array(input.fixturePayload.utf8), timeoutMS: input.deadlineExpired ? 0 : 5_000), nowMS: UInt32(step.timeMilliseconds))
            case .query: receipt = await runtime.request(.query(correlationID: correlation!, payload: Array(input.fixturePayload.utf8), timeoutMS: input.deadlineExpired ? 0 : 5_000), nowMS: UInt32(step.timeMilliseconds))
            case .update: receipt = await runtime.request(.update(correlationID: correlation!, payload: Array(input.fixturePayload.utf8), timeoutMS: input.deadlineExpired ? 0 : 5_000), nowMS: UInt32(step.timeMilliseconds))
            case .call: receipt = await runtime.request(.call(correlationID: correlation!, payload: Array(input.fixturePayload.utf8), timeoutMS: input.deadlineExpired ? 0 : 5_000), nowMS: UInt32(step.timeMilliseconds))
            case .resolve: receipt = await runtime.respond(.resolve(correlationID: correlation!, payload: Array(input.fixturePayload.utf8)), nowMS: UInt32(step.timeMilliseconds))
            case .retrieve: receipt = await runtime.respond(.retrieve(correlationID: correlation!, payload: Array(input.fixturePayload.utf8)), nowMS: UInt32(step.timeMilliseconds))
            case .complete: receipt = await runtime.respond(.complete(correlationID: correlation!, payload: Array(input.fixturePayload.utf8)), nowMS: UInt32(step.timeMilliseconds))
            case .return: receipt = await runtime.respond(.returnEvent(correlationID: correlation!, payload: Array(input.fixturePayload.utf8)), nowMS: UInt32(step.timeMilliseconds))
            }
        } else {
            let correlationText = correlation.map(Self.uuidText)
            let topic = "coaty/3/trace/\(input.family.rawValue)/\(Self.uuidText(source))"
                + (correlationText.map { "/\($0)" } ?? "")
            receipt = await runtime.receive(.profile(topic: topic, payload: Array(input.fixturePayload.utf8), nowMS: UInt32(step.timeMilliseconds)))
        }
        return (receipt, await runtime.conformanceObservation())
    }

    private static func observation(
        receipt: RuntimeReceipt,
        projection: RuntimeConformanceObservation,
        step: TraceStep,
        labels: TraceLabels
    ) -> TraceObservation {
        let state = TraceState(
            activeObjectIDs: projection.state.activeObjectIDs.map { labels.objectLabel(for: $0) ?? uuidText($0) },
            pendingCorrelationIDs: projection.state.pendingCorrelationIDs.map { labels.correlationLabel(for: $0) ?? uuidText($0) },
            associationIDs: projection.state.associationSourceIDs.map { labels.associationLabel(for: $0) ?? uuidText($0) },
            generation: Int(projection.state.generation)
        )
        switch receipt {
        case .accepted:
            return TraceObservation(
                actions: projection.actions.compactMap { action in
                    switch action {
                    case .publish(let value): return TraceAction(kind: "publish", family: SharedProtocolTraceReplay<64>.traceFamily(value.routingKey.capability), correlationID: value.routingKey.correlationID.map { labels.correlationLabel(for: $0) ?? uuidText($0) })
                    case .deliver(let value): return TraceAction(kind: "deliver", family: SharedProtocolTraceReplay<64>.traceFamily(value.routingKey.capability), correlationID: value.routingKey.correlationID.map { labels.correlationLabel(for: $0) ?? uuidText($0) })
                    case .associationChanged(let value): return TraceAction(kind: "deliver", family: SharedProtocolTraceReplay<64>.traceFamily(value.delivery.routingKey.capability), correlationID: value.delivery.routingKey.correlationID.map { labels.correlationLabel(for: $0) ?? uuidText($0) })
                    case .externalRouteActivated, .externalRouteDeactivated: return nil
                    }
                },
                rejection: nil,
                nextState: state
            )
        case .ignored:
            return TraceObservation(actions: [], rejection: nil, nextState: state)
        case .rejected(let rejection):
            let code: TraceRejectionCode
            switch rejection {
            case .capacityExceeded: code = step.input.payloadBytes > step.limits.maximumPayloadBytes ? .payloadTooLarge : .saturated
            case .malformedFrame, .malformedPayload, .invalidOperationName: code = .malformed
            case .protocol(let value): code = SharedProtocolTraceReplay<64>.traceCode(value)
            case .notRunning: code = .malformed
            case .staleTransport: code = .malformed
            }
            return TraceObservation(actions: [], rejection: TraceRejection(code: code, reason: SharedProtocolTraceReplay<64>.reason(code)), nextState: state)
        }
    }

    private static func identity(_ value: String) -> UUID16 {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return UUID16(bytes: (
            UInt8(truncatingIfNeeded: hash >> 24), UInt8(truncatingIfNeeded: hash >> 16),
            UInt8(truncatingIfNeeded: hash >> 8), UInt8(truncatingIfNeeded: hash),
            0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1
        ))
    }

    private static func uuidText(_ id: UUID16) -> String {
        let bytes = id.bytes
        return String(format: "%02x%02x%02x%02x-0000-4000-8000-000000000001", bytes.0, bytes.1, bytes.2, bytes.3)
    }
}

private protocol TraceReplaySink: ~Copyable, ProtocolActionSink {
    var count: Int { get }
    subscript(index: Int) -> BorrowedProtocolAction? { get }
    mutating func removeAll()
}

extension InlineProtocolActionSink: TraceReplaySink {}
extension ReusableProtocolActionSink: TraceReplaySink {}

fileprivate struct TraceLabels {
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

/// The static adapter uses the fixed-runtime replay below; the host adapter
/// above enters the production ``AxolotyRuntime`` seam. The shared processor
/// replay remains the static reference implementation used by the embedded
/// profile verifier.
fileprivate struct SharedProtocolTraceReplay<let capacity: Int>: ~Copyable {
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

    mutating func replay<S: ~Copyable & TraceReplaySink>(
        _ trace: ProtocolTrace,
        sink: inout S
    ) throws -> TraceRun {
        var staticVerifier: StaticTraceVerifier<capacity>?
        return try replay(trace, sink: &sink, staticVerifier: &staticVerifier)
    }

    mutating func replay<S: ~Copyable & TraceReplaySink>(
        _ trace: ProtocolTrace,
        sink: inout S,
        staticVerifier: inout StaticTraceVerifier<capacity>?
    ) throws -> TraceRun {
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
                if staticVerifier != nil {
                    try staticVerifier!.seed(state: state, time: step.timeMilliseconds)
                }
                seeded = true
            }
            let outcome = try Self.process(step, processor: &processor, sink: &sink)
            processor.copyState(into: &projection)
            let generation = processor.state.generation
            let observation = Self.observation(for: outcome, step: step, projection: projection, generation: generation, sink: sink, labels: labels)
            guard observation == step.expected else { throw TraceReplayError.expectedMismatch(traceID: trace.id, sequence: step.sequence) }
            if staticVerifier != nil {
                let staticObservation = try staticVerifier!.process(step: step, labels: labels)
                guard staticObservation == observation else {
                    throw TraceReplayError.expectedMismatch(traceID: trace.id, sequence: step.sequence)
                }
            }
            if observation.rejection == nil { state = observation.nextState }
            observations.append(observation)
            sink.removeAll()
        }
        return TraceRun(traceID: trace.id, observations: observations)
    }

    fileprivate static func seedObject<S: ~Copyable & ProtocolActionSink>(_ name: String, processor: inout ProtocolProcessor<capacity>, sink: inout S, time: UInt64) throws {
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

    fileprivate static func process<S: ~Copyable & ProtocolActionSink>(_ step: TraceStep, processor: inout ProtocolProcessor<capacity>, sink: inout S) throws -> ProtocolProcessOutcome {
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

    fileprivate static func observation<S: ~Copyable & TraceReplaySink>(for outcome: ProtocolProcessOutcome, step: TraceStep, projection: borrowing ProtocolFixedStateSnapshot<capacity>, generation: UInt32, sink: borrowing S, labels: borrowing TraceLabels) -> TraceObservation {
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
    fileprivate static func capability(_ family: TraceEventFamily) -> ProtocolCapability {
        switch family { case .advertise: return .advertise; case .deadvertise: return .deadvertise; case .channel: return .channel; case .associate: return .associate; case .ioValue: return .ioValue; case .discover: return .discover; case .resolve: return .resolve; case .query: return .query; case .retrieve: return .retrieve; case .update: return .update; case .complete: return .complete; case .call: return .call; case .return: return .returnEvent }
    }
    fileprivate static func traceFamily(_ capability: ProtocolCapability) -> TraceEventFamily {
        switch capability { case .advertise: return .advertise; case .deadvertise: return .deadvertise; case .channel: return .channel; case .associate: return .associate; case .ioValue: return .ioValue; case .discover: return .discover; case .resolve: return .resolve; case .query: return .query; case .retrieve: return .retrieve; case .update: return .update; case .complete: return .complete; case .call: return .call; case .returnEvent: return .return }
    }

    fileprivate static func capabilities(_ families: [TraceEventFamily]) throws -> ProtocolCapabilities {
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

    fileprivate static func snapshot(_ state: borrowing ProtocolFixedStateSnapshot<capacity>, generation: UInt32, labels: borrowing TraceLabels) -> TraceState {
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

    fileprivate static func traceCode(_ code: ProtocolError.Code) -> TraceRejectionCode {
        switch code { case .malformedFrame, .malformedPayload, .invalidCorrelation, .invalidEndpoint: return .malformed; case .unsupportedCapability: return .unsupported; case .capacityExceeded: return .saturated; case .duplicate: return .duplicate; case .deadlineExpired: return .deadlineExpired; case .correlationMismatch: return .correlationMismatch; case .externalRouteMismatch: return .externalRouteMismatch; case .borrowedValueEscaped: return .malformed }
    }
    fileprivate static func reason(_ code: TraceRejectionCode) -> String {
        switch code { case .payloadTooLarge: return "payload exceeds bounded trace workspace"; case .malformed: return "fixture is marked malformed"; case .deadlineExpired: return "operation deadline has elapsed"; case .unsupported: return "family is outside the runtime capability set"; case .duplicate: return "object is already active"; case .saturated: return "object table is at capacity"; case .correlationMismatch: return "response correlation is not pending"; case .externalRouteMismatch: return "external route flag does not match the binding route" }
    }
}

/// Drives the real fixed-storage runtime alongside the host trace replay.
///
/// The host adapter remains the observation producer, while this verifier
/// executes every seed and trace step through ``StaticRuntimeESP32C6`` and
/// compares the copied action/state/rejection projection before the trace can
/// pass. This keeps the equality assertion honest without making borrowed
/// static-runtime values escape their synchronous drain scope.
fileprivate struct StaticTraceVerifier<let traceCapacity: Int>: ~Copyable {
    private var runtime: StaticRuntimeESP32C6
    private let firstFamily: TraceEventFamily

    init(trace: ProtocolTrace) throws {
        let firstStep = trace.steps.first
        firstFamily = firstStep?.input.family ?? .resolve
        let capabilities = try SharedProtocolTraceReplay<traceCapacity>.capabilities(
            firstStep?.capabilities.supportedFamilies ?? TraceEventFamily.allCases
        )
        runtime = StaticRuntimeESP32C6(
            registryID: ObjectID(uuid: Self.identity("trace-static-registry")),
            capabilities: capabilities,
            maximumObjects: firstStep?.limits.maximumObjects ?? 16,
            maximumPendingCorrelations: firstStep?.limits.maximumPendingCorrelations ?? 16
        )
    }

    mutating func seed(state: TraceState, time: UInt64) throws {
        for objectID in state.activeObjectIDs {
            try seedObject(objectID, time: time)
        }
        if let correlationID = state.pendingCorrelationIDs.first {
            let request = Self.requestSeed(for: firstFamily)
            try Self.withBorrowedPayload(request.payload) { payload in
                let operation = try ProtocolLocalOperation(
                    capability: request.capability,
                    sourceID: Self.identity("trace-requester"),
                    correlationID: Self.identity(correlationID),
                    payload: payload,
                    requestTimeoutMS: 5_000
                )
                _ = runtime.send(operation, nowMS: UInt32(time))
                _ = drainOwned()
            }
        }
    }

    fileprivate mutating func process(
        step: TraceStep,
        labels: borrowing TraceLabels
    ) throws -> TraceObservation {
        let (outcome, actions) = try processStep(step)
        var projection = ProtocolFixedStateSnapshot<16>()
        runtime.copyState(into: &projection)
        let nextState = SharedProtocolTraceReplay<16>.snapshot(
            projection,
            generation: runtime.state.generation,
            labels: labels
        )
        switch outcome {
        case .accepted:
            return TraceObservation(
                actions: actions.compactMap { action in
                    switch action {
                    case .publish(let publication):
                        return TraceAction(
                            kind: "publish",
                            family: SharedProtocolTraceReplay<traceCapacity>.traceFamily(publication.routingKey.capability),
                            correlationID: publication.routingKey.correlationID.map {
                                labels.correlationLabel(for: $0) ?? Self.uuidText($0)
                            }
                        )
                    case .deliver(let delivery):
                        return TraceAction(
                            kind: "deliver",
                            family: SharedProtocolTraceReplay<traceCapacity>.traceFamily(delivery.routingKey.capability),
                            correlationID: delivery.routingKey.correlationID.map {
                                labels.correlationLabel(for: $0) ?? Self.uuidText($0)
                            }
                        )
                    case .associationChanged(let transition):
                        return TraceAction(
                            kind: "deliver",
                            family: SharedProtocolTraceReplay<traceCapacity>.traceFamily(transition.delivery.routingKey.capability),
                            correlationID: transition.delivery.routingKey.correlationID.map {
                                labels.correlationLabel(for: $0) ?? Self.uuidText($0)
                            }
                        )
                    case .externalRouteActivated, .externalRouteDeactivated:
                        return nil
                    }
                },
                rejection: nil,
                nextState: nextState
            )
        case .ignored:
            return TraceObservation(actions: [], rejection: nil, nextState: nextState)
        case .rejected(let code):
            let traceCode = step.input.payloadBytes > step.limits.maximumPayloadBytes
                && code == .capacityExceeded ? TraceRejectionCode.payloadTooLarge
                : SharedProtocolTraceReplay<traceCapacity>.traceCode(code)
            return TraceObservation(
                actions: [],
                rejection: TraceRejection(code: traceCode, reason: SharedProtocolTraceReplay<traceCapacity>.reason(traceCode)),
                nextState: nextState
            )
        }
    }

    private mutating func seedObject(_ name: String, time: UInt64) throws {
        let object = Self.identity(name)
        let topic = "coaty/3/trace/ADV/\(Self.uuidText(object))"
        let payload = "{\"object\":{\"objectId\":\"\(Self.uuidText(object))\",\"coreType\":\"CoatyObject\",\"objectType\":\"trace.Object\",\"name\":\"\(name)\"}}"
        _ = try Self.withBorrowed(topic: topic, payload: payload) { frame in
            runtime.receive(frame, nowMS: UInt32(time))
        }
        _ = drainOwned()
    }

    private mutating func processStep(_ step: TraceStep) throws -> (ProtocolProcessOutcome, [OwnedProtocolAction]) {
        let input = step.input
        let source = Self.identity(input.objectID ?? "trace-source")
        let capability = SharedProtocolTraceReplay<traceCapacity>.capability(input.family)
        let correlation = input.correlationID.map(Self.identity)
            ?? (capability.isOneWay ? nil : Self.identity("malformed-correlation"))
        let topic = "coaty/3/trace/\(input.family.rawValue)/\(Self.uuidText(source))"
            + (correlation.map { "/\(Self.uuidText($0))" } ?? "")
        let outcome: ProtocolProcessOutcome
        if input.direction == .outbound {
            outcome = try Self.withBorrowedPayload(input.fixturePayload) { payload in
                let operation = try ProtocolLocalOperation(
                    capability: capability,
                    sourceID: source,
                    correlationID: correlation,
                    payload: payload,
                    requestTimeoutMS: input.deadlineExpired ? 0 : (correlation == nil ? nil : 5_000)
                )
                return runtime.send(operation, nowMS: UInt32(step.timeMilliseconds))
            }
        } else {
            outcome = try Self.withBorrowed(topic: topic, payload: input.fixturePayload) { frame in
                let classifier = StaticTraceClassifier(
                    classification: input.routeClassification == .external ? .external : .coaty
                )
                return runtime.receive(
                    frame,
                    nowMS: UInt32(step.timeMilliseconds),
                    classifier: classifier
                )
            }
        }
        return (outcome, drainOwned())
    }

    private mutating func drainOwned() -> [OwnedProtocolAction] {
        var actions: [OwnedProtocolAction] = []
        runtime.drainActions { action in actions.append(action.owned()) }
        return actions
    }

    private struct StaticTraceClassifier: ProtocolRouteClassifier, Sendable {
        let classification: ProtocolRouteClassification
        func classify(_: ByteSlice) -> ProtocolRouteClassification { classification }
    }

    private static func withBorrowed<R>(topic: String, payload: String, _ body: (BorrowedProtocolFrame) throws -> R) throws -> R {
        let topicBytes = Array(topic.utf8)
        let payloadBytes = Array(payload.utf8)
        return try topicBytes.withUnsafeBufferPointer { topicBuffer in
            try payloadBytes.withUnsafeBufferPointer { payloadBuffer in
                let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
                return try body(try BorrowedProtocolFrame(
                    topic: view,
                    payload: ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
                ))
            }
        }
    }

    private static func withBorrowedPayload<R>(_ payload: String, _ body: (ByteSlice) throws -> R) throws -> R {
        let bytes = Array(payload.utf8)
        return try bytes.withUnsafeBufferPointer {
            try body(ByteSlice(bytes: $0.baseAddress!, length: $0.count))
        }
    }

    private static func requestSeed(for family: TraceEventFamily) -> (capability: ProtocolCapability, payload: String) {
        switch family {
        case .resolve: return (.discover, "{}")
        case .retrieve: return (.query, "{}")
        case .complete: return (.update, "{\"object\":{\"id\":\"x\"}}")
        case .return: return (.call, "{\"parameters\":{\"value\":1},\"filter\":null}")
        default: return (.discover, "{}")
        }
    }

    private static func identity(_ value: String) -> UUID16 {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return UUID16(bytes: (
            UInt8(truncatingIfNeeded: hash >> 24),
            UInt8(truncatingIfNeeded: hash >> 16),
            UInt8(truncatingIfNeeded: hash >> 8),
            UInt8(truncatingIfNeeded: hash), 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1
        ))
    }

    private static func uuidText(_ id: UUID16) -> String {
        let bytes = id.bytes
        return String(format: "%02x%02x%02x%02x-0000-4000-8000-000000000001", bytes.0, bytes.1, bytes.2, bytes.3)
    }
}

enum ProtocolTraceCanonicalEncoding {
    static func data(for traces: [ProtocolTrace]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(traces)
    }
}
