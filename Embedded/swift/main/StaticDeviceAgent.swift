// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import AxolotyProtocol

@inline(__always)
private func staticDeviceAgentNoop(
    _: UInt32,
    _: UnsafePointer<UInt8>?, _: Int,
    _: UnsafePointer<UInt8>?, _: Int
) {}

enum StaticDeviceDispatchResult: Equatable {
    case advertise
    case deadvertise
    case discover
    case resolve
    case wrongCorrelation
    case duplicateResolve
    case malformed
    case unsupported
    case ioSourceAssociated
    case ioSourceDisassociated
    case ioActorAssociated
    case ioActorDisassociated
    case ioValueDelivered
}

private extension BorrowedProtocolDeliveryKey {
    func isActor(actorId: UUID16) -> Bool {
        if case .ioActor(let candidate) = self { return candidate == actorId }
        return false
    }
}

/// The production static device-agent ingress for the embedded firmware.
///
/// This type delegates protocol decisions to the shared fixed-inline
/// ``ProtocolProcessor``. Endpoint callbacks remain caller-owned firmware
/// state; the processor owns correlation, capacity, and association semantics.
///
/// The value is intentionally non-`Sendable`: one firmware callback owns and
/// mutates it synchronously. Transport callbacks remain outside this module.
struct StaticDeviceAgent: ~Copyable {
    static let agentAId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
    ))
    static let objectAId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02
    ))
    static let agentBId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0b
    ))
    static let objectBId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c
    ))
    static let agentId = agentAId
    static let deviceObjectId = objectAId
    static let namespace: StaticString = "axoloty-embedded"

    // The firmware has a deliberately small, static endpoint profile. These
    // UUIDs are endpoint identities, not agent identities, and stay stable so
    // a host IoRouter can associate them without on-device discovery.
    static let sourceAId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21
    ))
    static let actorAId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x22
    ))
    static let sourceBId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x31
    ))
    static let actorBId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x32
    ))

    let agentId: UUID16
    let deviceObjectId: UUID16
    private(set) var hasAdvertisedPeer = false
    private var processor: ProtocolProcessor<16>
    private let routeClassifier: ExactProtocolRouteClassifier
    private var subscriptions: ProtocolSubscriptionRegistry<16>
    private var actionSink = InlineProtocolActionSink<16>()

    /// The object-type filter the device advertises with and discovers under.
    /// Matches the `ADV:<filter>` topic bytes after the `:` separator and the
    /// lookup filter used by ``dispatch(_:nowMS:)``.
    static let deviceFilter: StaticString = "coaty.test.Device"

    // A missing Resolve expires after five seconds; the C wait loop polls this
    // synchronous state while the MQTT client remains connected.
    private static let discoverTimeoutMS: UInt32 = 5_000

    init(agentId: UUID16 = StaticDeviceAgent.agentAId, deviceObjectId: UUID16 = StaticDeviceAgent.objectAId) {
        self.agentId = agentId
        self.deviceObjectId = deviceObjectId
        self.routeClassifier = ExactProtocolRouteClassifier(
            externalRoute: "external/wire-compat-v1/io-external-1"
        )
        self.processor = ProtocolProcessor<16>(
            capabilities: .coatyCore3,
            maximumPayloadBytes: WireBufferConfig.maxPayloadSize
        )
        let isA = agentId == Self.agentAId
        self.subscriptions = ProtocolSubscriptionRegistry<16>()
        self.actionSink = InlineProtocolActionSink<16>()
        let actorId = isA ? Self.actorAId : Self.actorBId
        _ = try! self.subscriptions.register(
            selector: .ioActor(actorId),
            handler: ProtocolHandlerEntry(function: staticDeviceAgentNoop, context: 0)
        )
    }

    /// Starts a bounded Discover request through the processor's outbound
    /// operation seam. The emitted action is discarded by this firmware-only
    /// convenience because the transport already owns the encoded buffers.
    mutating func beginDiscover(correlationId: UUID16, nowMS: UInt32) -> Bool {
        let payloadText: StaticString = "{}"
        let payload = ByteSlice(bytes: payloadText.utf8Start, length: payloadText.utf8CodeUnitCount)
        guard let operation = try? ProtocolLocalOperation(
            capability: .discover,
            sourceID: agentId,
            correlationID: correlationId,
            payload: payload,
            requestTimeoutMS: Self.discoverTimeoutMS
        ) else { return false }
        actionSink.removeAll()
        let outcome = processor.processOutbound(operation, nowMS: nowMS, sink: &actionSink)
        actionSink.removeAll()
        return outcome == .accepted
    }

    /// Expires the outstanding Discover once its deadline has passed.
    ///
    /// Time is supplied by the caller so this static processor remains
    /// deterministic and does not need an asynchronous task.
    mutating func expireDiscover(nowMS: UInt32) -> Bool {
        processor.expire(nowMS: nowMS)
    }

    mutating func dispatch(_ message: BorrowedMessage, nowMS: UInt32) -> StaticDeviceDispatchResult {
        if message.eventType == .discover,
           let filter = message.topic.eventTypeFilter,
           !filter.equals(Self.deviceFilter) {
            return .unsupported
        }
        guard let frame = try? BorrowedProtocolFrame(topic: message.topic, payload: message.payload) else {
            return .malformed
        }
        actionSink.removeAll()
        let outcome = processor.processInbound(
            .profile(frame), nowMS: nowMS, classifier: routeClassifier, sink: &actionSink
        )
        guard outcome == .accepted else {
            switch outcome {
            case .ignored: return .unsupported
            case .rejected(.duplicate): return .duplicateResolve
            case .rejected(.correlationMismatch), .rejected(.deadlineExpired): return .wrongCorrelation
            default: return .malformed
            }
        }

        guard let action = actionSink[0] else { return .malformed }
        let actorId = agentId == Self.agentAId ? Self.actorAId : Self.actorBId
        var actorDelivery = false
        for index in 0..<actionSink.count {
            if let deliveredAction = actionSink[index] {
                switch deliveredAction {
                case .deliver(let delivery):
                    _ = subscriptions.dispatch(deliveredAction)
                    actorDelivery = actorDelivery || delivery.deliveryKey.isActor(actorId: actorId)
                case .associationChanged(let transition):
                    _ = subscriptions.dispatch(deliveredAction)
                    actorDelivery = actorDelivery || transition.delivery.deliveryKey.isActor(actorId: actorId)
                case .publish, .externalRouteActivated, .externalRouteDeactivated:
                    break
                }
            }
        }
        actionSink.removeAll()
        if case .associationChanged(let transition) = action {
            switch transition.change {
            case .established, .updated:
                return actorDelivery ? .ioActorAssociated : .ioSourceAssociated
            case .removed:
                return actorDelivery ? .ioActorDisassociated : .ioSourceDisassociated
            }
        }
        switch message.eventType {
        case .advertise:
            hasAdvertisedPeer = true; return .advertise
        case .deadvertise:
            hasAdvertisedPeer = false; return .deadvertise
        case .discover:
            return .discover
        case .resolve:
            return .resolve
        case .ioValue:
            return actorDelivery ? .ioValueDelivered : .malformed
        default:
            return .unsupported
        }
    }

    mutating func encode<T: WireEncodable>(
        _ value: T,
        eventType: WireEventType,
        correlationId: UUID16?,
        nowMS: UInt32,
        topicBuffer: UnsafeMutablePointer<UInt8>,
        topicCapacity: Int,
        payloadBuffer: UnsafeMutablePointer<UInt8>,
        payloadCapacity: Int
    ) throws(WireEncodeError) -> (topicLength: Int, payloadLength: Int) {
        var topic = TopicBuilder(buffer: topicBuffer, capacity: topicCapacity)
        try topic.writePrefix()
        try topic.writeNamespace(Self.namespace)
        let objectTypeFilter: StaticString = "coaty.test.Device"
        let filter = eventType == .advertise
            ? ByteSlice(bytes: objectTypeFilter.utf8Start, length: objectTypeFilter.utf8CodeUnitCount)
            : nil
        try topic.writeEventType(eventType, filter: filter)
        try topic.writeSourceId(agentId)
        if let correlationId { try topic.writeCorrelationId(correlationId) }

        var payload = WireWriter(buffer: payloadBuffer, capacity: payloadCapacity)
        try value.encode(to: &payload)
        let borrowedPayload = ByteSlice(bytes: payloadBuffer, length: payload.position)
        let capability = ProtocolCapability(wireEventType: eventType)
        guard let capability else { throw .invalidValue }
        guard let operation = try? ProtocolLocalOperation(
            capability: capability,
            sourceID: agentId,
            correlationID: correlationId,
            payload: borrowedPayload,
            requestTimeoutMS: eventType == .discover ? Self.discoverTimeoutMS : nil
        ) else { throw .invalidValue }
        var actionSink = InlineProtocolActionSink<1>()
        let outcome = processor.processOutbound(
            operation, nowMS: nowMS, classifier: routeClassifier, sink: &actionSink
        )
        actionSink.removeAll()
        guard outcome == .accepted else {
            throw .invalidValue
        }
        return (topic.position, payload.position)
    }

    /// Copies the currently associated local actor route into fixed caller
    /// storage for ESP-MQTT subscribe/reconnect operations.
    func copyActorRoute(
        to output: UnsafeMutablePointer<UInt8>, capacity: Int
    ) -> Int? {
        let actorId = agentId == Self.agentAId ? Self.actorAId : Self.actorBId
        return processor.copyActorRoute(actorId: actorId, to: output, capacity: capacity)
    }
}

private let phase4Correlation = UUID16(bytes: (
    0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
    0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04
))

private var phase4AgentA = StaticDeviceAgent(
    agentId: StaticDeviceAgent.agentAId,
    deviceObjectId: StaticDeviceAgent.objectAId
)

private var phase4AgentB = StaticDeviceAgent(
    agentId: StaticDeviceAgent.agentBId,
    deviceObjectId: StaticDeviceAgent.objectBId
)

@inline(__always)
func phase4NowMS() -> UInt32 {
    UInt32(truncatingIfNeeded: esp_timer_get_time() / 1_000)
}

private func phase4Encode<T: WireEncodable>(
    role: Int32,
    value: T,
    eventType: WireEventType,
    correlationId: UUID16?,
    topicBuffer: UnsafeMutablePointer<UInt8>,
    topicCapacity: Int32,
    payloadBuffer: UnsafeMutablePointer<UInt8>,
    payloadCapacity: Int32
) throws(WireEncodeError) -> (topicLength: Int, payloadLength: Int) {
    if role == 1 {
        return try phase4AgentA.encode(
            value, eventType: eventType, correlationId: correlationId, nowMS: phase4NowMS(),
            topicBuffer: topicBuffer, topicCapacity: Int(topicCapacity),
            payloadBuffer: payloadBuffer, payloadCapacity: Int(payloadCapacity)
        )
    }
    return try phase4AgentB.encode(
        value, eventType: eventType, correlationId: correlationId, nowMS: phase4NowMS(),
        topicBuffer: topicBuffer, topicCapacity: Int(topicCapacity),
        payloadBuffer: payloadBuffer, payloadCapacity: Int(payloadCapacity)
    )
}

@_cdecl("axoloty_static_agent_expire")
func axolotyStaticAgentExpire(_ role: Int32) -> Int32 {
    role == 2 && phase4AgentB.expireDiscover(nowMS: phase4NowMS()) ? 1 : 0
}

/// Copies the active actor route for the selected static endpoint profile.
/// The C MQTT adapter invokes this only to subscribe or re-subscribe; route
/// bytes never escape into asynchronous Swift state.
@_cdecl("axoloty_static_agent_copy_actor_route")
func axolotyStaticAgentCopyActorRoute(
    _ role: Int32, _ output: UnsafeMutablePointer<UInt8>, _ capacity: Int32
) -> Int32 {
    guard capacity > 0 else { return -1 }
    let length = role == 1
        ? phase4AgentA.copyActorRoute(to: output, capacity: Int(capacity))
        : phase4AgentB.copyActorRoute(to: output, capacity: Int(capacity))
    return Int32(length ?? -1)
}

@inline(__always)
private func preparePhase4Message(
    role: Int32,
    kind: Int32,
    responseCorrelationId: UUID16? = nil,
    topicBuffer: UnsafeMutablePointer<UInt8>,
    topicCapacity: Int32,
    payloadBuffer: UnsafeMutablePointer<UInt8>,
    payloadCapacity: Int32,
    topicLength: UnsafeMutablePointer<Int32>,
    payloadLength: UnsafeMutablePointer<Int32>
) -> Bool {
    let source: StaticString
    let eventType: WireEventType
    let correlationId: UUID16?
    switch (role, kind) {
    case (1, 1):
        source = "{\"object\":{\"coreType\":\"CoatyObject\",\"objectId\":\"32400000-0000-4000-8000-000000000002\",\"objectType\":\"coaty.test.Device\",\"name\":\"ESP32-C6 A\"}}"
        eventType = .advertise; correlationId = nil
    case (2, 2):
        source = "{\"objectTypes\":[\"coaty.test.Device\"]}"
        eventType = .discover; correlationId = phase4Correlation
    case (1, 3):
        source = "{\"object\":{\"coreType\":\"CoatyObject\",\"objectId\":\"32400000-0000-4000-8000-000000000002\",\"objectType\":\"coaty.test.Device\",\"name\":\"ESP32-C6 A\"}}"
        eventType = .resolve; correlationId = responseCorrelationId ?? phase4Correlation
    case (1, 4):
        source = "{\"objectIds\":[\"32400000-0000-4000-8000-000000000002\"]}"
        eventType = .deadvertise; correlationId = nil
    default:
        return false
    }

    let result: (topicLength: Int, payloadLength: Int)?
    let reader = WireReader(bytes: source.utf8Start, length: source.utf8CodeUnitCount)
    switch eventType {
    case .advertise:
        result = (try? AdvertiseWireData(from: reader)).flatMap {
            try? phase4Encode(role: role, value: $0, eventType: eventType, correlationId: correlationId,
                              topicBuffer: topicBuffer, topicCapacity: topicCapacity,
                              payloadBuffer: payloadBuffer, payloadCapacity: payloadCapacity)
        }
    case .deadvertise:
        result = (try? DeadvertiseWireData(from: reader)).flatMap {
            try? phase4Encode(role: role, value: $0, eventType: eventType, correlationId: correlationId,
                              topicBuffer: topicBuffer, topicCapacity: topicCapacity,
                              payloadBuffer: payloadBuffer, payloadCapacity: payloadCapacity)
        }
    case .discover:
        result = (try? DiscoverWireData(from: reader)).flatMap {
            try? phase4Encode(role: role, value: $0, eventType: eventType, correlationId: correlationId,
                              topicBuffer: topicBuffer, topicCapacity: topicCapacity,
                              payloadBuffer: payloadBuffer, payloadCapacity: payloadCapacity)
        }
    case .resolve:
        result = (try? ResolveWireData(from: reader)).flatMap {
            try? phase4Encode(role: role, value: $0, eventType: eventType, correlationId: correlationId,
                              topicBuffer: topicBuffer, topicCapacity: topicCapacity,
                              payloadBuffer: payloadBuffer, payloadCapacity: payloadCapacity)
        }
    default:
        result = nil
    }
    guard let result else { return false }
    topicLength.pointee = Int32(result.topicLength)
    payloadLength.pointee = Int32(result.payloadLength)
    return true
}

@_cdecl("axoloty_static_agent_prepare")
func axolotyStaticAgentPrepare(
    _ role: Int32,
    _ kind: Int32,
    _ topicBuffer: UnsafeMutablePointer<UInt8>,
    _ topicCapacity: Int32,
    _ payloadBuffer: UnsafeMutablePointer<UInt8>,
    _ payloadCapacity: Int32,
    _ topicLength: UnsafeMutablePointer<Int32>,
    _ payloadLength: UnsafeMutablePointer<Int32>
) -> Int32 {
    preparePhase4Message(
        role: role, kind: kind,
        topicBuffer: topicBuffer, topicCapacity: topicCapacity,
        payloadBuffer: payloadBuffer, payloadCapacity: payloadCapacity,
        topicLength: topicLength, payloadLength: payloadLength
    ) ? 1 : 0
}

@_cdecl("axoloty_static_agent_receive")
func axolotyStaticAgentReceive(
    _ role: Int32,
    _ topicBytes: UnsafePointer<UInt8>,
    _ topicLength: Int32,
    _ payloadBytes: UnsafePointer<UInt8>,
    _ payloadLength: Int32,
    _ outputTopic: UnsafeMutablePointer<UInt8>,
    _ outputTopicCapacity: Int32,
    _ outputPayload: UnsafeMutablePointer<UInt8>,
    _ outputPayloadCapacity: Int32,
    _ outputTopicLength: UnsafeMutablePointer<Int32>,
    _ outputPayloadLength: UnsafeMutablePointer<Int32>
) -> Int32 {
    guard let message = try? BorrowedMessage.validated(
        topicBytes: topicBytes, topicLength: Int(topicLength),
        payloadBytes: payloadBytes, payloadLength: Int(payloadLength)
    ) else { return -1 }

    let nowMS = phase4NowMS()
    if role == 1 && message.eventType == .discover {
        guard phase4AgentA.dispatch(message, nowMS: nowMS) == .discover else { return -1 }
        guard let correlationId = message.topic.correlationIdLevel.flatMap(UUID16.init(parsing:)) else { return -1 }
        return preparePhase4Message(
            role: role, kind: 3, responseCorrelationId: correlationId,
            topicBuffer: outputTopic, topicCapacity: outputTopicCapacity,
            payloadBuffer: outputPayload, payloadCapacity: outputPayloadCapacity,
            topicLength: outputTopicLength, payloadLength: outputPayloadLength
        ) ? 1 : -1
    }
    if role == 2 && message.eventType == .advertise {
        guard phase4AgentB.dispatch(message, nowMS: nowMS) == .advertise else { return -1 }
        let prepared = preparePhase4Message(
            role: role, kind: 2,
            topicBuffer: outputTopic, topicCapacity: outputTopicCapacity,
            payloadBuffer: outputPayload, payloadCapacity: outputPayloadCapacity,
            topicLength: outputTopicLength, payloadLength: outputPayloadLength
        )
        return prepared ? 1 : -1
    }
    if role == 2 && message.eventType == .resolve {
        return phase4AgentB.dispatch(message, nowMS: nowMS) == .resolve ? 2 : -1
    }
    if role == 2 && message.eventType == .deadvertise {
        return phase4AgentB.dispatch(message, nowMS: nowMS) == .deadvertise ? 3 : -1
    }
    if message.eventType == .associate {
    let result: StaticDeviceDispatchResult
    if role == 1 {
        result = phase4AgentA.dispatch(message, nowMS: nowMS)
    } else {
        result = phase4AgentB.dispatch(message, nowMS: nowMS)
    }
        switch result {
        case .ioActorAssociated: return 4
        case .ioActorDisassociated: return 5
        case .ioSourceAssociated, .ioSourceDisassociated: return 0
        default: return -1
        }
    }
    if message.eventType == .ioValue {
        let result: StaticDeviceDispatchResult
        if role == 1 {
            result = phase4AgentA.dispatch(message, nowMS: nowMS)
        } else {
            result = phase4AgentB.dispatch(message, nowMS: nowMS)
        }
        return result == .ioValueDelivered ? 6 : -1
    }
    return 0
}
