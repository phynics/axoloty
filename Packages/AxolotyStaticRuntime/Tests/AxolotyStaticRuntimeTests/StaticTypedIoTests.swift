// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyStaticRuntime
import AxolotyWire

private func typedIoID(_ literal: StaticString) -> ObjectID {
    ObjectID(bytes: ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount))!
}

private func typedPayload(_ literal: StaticString) -> ByteSlice {
    ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount)
}

private func typedSourceMetadata(_ literal: StaticString) throws -> Object<IoSourceMetadata> {
    try Object<IoSourceMetadata>(decoding: ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount))
}

private func typedActorMetadata(_ literal: StaticString) throws -> Object<IoActorMetadata> {
    try Object<IoActorMetadata>(decoding: ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount))
}

private func withStaticInbound<R>(
    topic: String,
    payload: String,
    _ body: (ByteSlice, ByteSlice) -> R
) -> R {
    let topicBytes = Array(topic.utf8)
    let payloadBytes = Array(payload.utf8)
    return topicBytes.withUnsafeBufferPointer { topicBuffer in
        payloadBytes.withUnsafeBufferPointer { payloadBuffer in
            body(
                ByteSlice(bytes: topicBuffer.baseAddress!, length: topicBuffer.count),
                ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
            )
        }
    }
}

nonisolated(unsafe) private var typedIoReceipt: (UInt32, Bool, UInt32, UInt32, IoRouteKind)?

@StaticIoActor(Bool.self)
private enum TypedBoolHandler {
    static func receive(
        context: UInt32,
        value: borrowing Bool,
        delivery: borrowing IoDeliveryContext
    ) {
        typedIoReceipt = (
            context,
            value == true,
            delivery.receivedAtMS,
            delivery.associationGeneration,
            delivery.routeKind
        )
    }
}

@StaticIoActor(DynamicIoValue.self)
private enum TypedDynamicHandler {
    static func receive(
        context: UInt32,
        value: borrowing DynamicIoValue,
        delivery: borrowing IoDeliveryContext
    ) {
        _ = context
        _ = value
        _ = delivery
    }
}

@Suite("Static typed IO")
struct StaticTypedIoTests {
    @Test("source registration uses the ordinary Advertise path")
    func sourceRegistration() throws {
        var runtime = StaticRuntimeESP32C6(
            registryID: typedIoID("00000000-0000-4000-8000-000000000010")
        )
        let source = try runtime.registerIoSource(
            metadata: typedSourceMetadata(#"{"objectId":"00000000-0000-4000-8000-000000000011","objectType":"coaty.IoSource","coreType":"IoSource","name":"typed-source","valueType":"com.example.bool"}"#),
            as: Bool.self,
            publication: .latest(atMostEveryMS: 25)
        )

        #expect(source.id == typedIoID("00000000-0000-4000-8000-000000000011"))
        #expect(runtime.actionCount == 1)
        var publications = 0
        #expect(runtime.drain { action in
            if case .publish = action { publications += 1 }
        } == 1)
        #expect(publications == 1)
        let sourceState = try runtime.ioAssociationState(of: source)
        #expect(sourceState.hasAssociations == false)
    }

    @Test("actor registration retains a macro entry and context")
    func actorRegistration() throws {
        var runtime = StaticRuntimeESP32C6(
            registryID: typedIoID("00000000-0000-4000-8000-000000000020")
        )
        let actor = try runtime.registerIoActor(
            metadata: typedActorMetadata(#"{"objectId":"00000000-0000-4000-8000-000000000021","objectType":"coaty.IoActor","coreType":"IoActor","name":"typed-actor","valueType":"com.example.bool"}"#),
            handler: StaticIoHandler(TypedBoolHandler.self, context: 9),
            recommendedUpdateRateMS: 0
        )

        #expect(actor.id == typedIoID("00000000-0000-4000-8000-000000000021"))
        #expect(runtime.actionCount == 1)
        _ = runtime.drain { _ in }
        let actorState = try runtime.ioAssociationState(of: actor)
        #expect(actorState.associationCount == 0)
    }

    @Test("foreign handles fail before publication state changes")
    func foreignHandle() throws {
        var first = StaticRuntimeESP32C6(
            registryID: typedIoID("00000000-0000-4000-8000-000000000030")
        )
        let source = try first.registerIoSource(
            metadata: typedSourceMetadata(#"{"objectId":"00000000-0000-4000-8000-000000000031","objectType":"coaty.IoSource","coreType":"IoSource","name":"foreign-source","valueType":"com.example.bool"}"#),
            as: Bool.self
        )
        _ = first.drain { _ in }

        var second = StaticRuntimeESP32C6(
            registryID: typedIoID("00000000-0000-4000-8000-000000000032")
        )
        #expect(second.publishIoValue(true, from: source, nowMS: 1) == .rejected(.invalidEndpoint))
        #expect(second.actionCount == 0)
    }

    @Test("tiny capacity commits one endpoint and rejects the next atomically")
    func tinyRegistrationIsAtomic() throws {
        var runtime = StaticRuntimeTiny(
            registryID: typedIoID("00000000-0000-4000-8000-000000000040")
        )
        let source = try runtime.registerIoSource(
            metadata: typedSourceMetadata(#"{"objectId":"00000000-0000-4000-8000-000000000041","objectType":"coaty.IoSource","coreType":"IoSource","name":"tiny-source","valueType":"com.example.bool"}"#),
            as: Bool.self
        )
        #expect(source.id == typedIoID("00000000-0000-4000-8000-000000000041"))
        #expect(runtime.actionCount == 1)
        _ = runtime.drain { _ in }
        do {
            _ = try runtime.registerIoActor(
                metadata: typedActorMetadata(#"{"objectId":"00000000-0000-4000-8000-000000000042","objectType":"coaty.IoActor","coreType":"IoActor","name":"tiny-actor","valueType":"com.example.bool"}"#),
                handler: StaticIoHandler(TypedBoolHandler.self, context: 1)
            )
            Issue.record("second endpoint unexpectedly succeeded")
        } catch let error as ProtocolError {
            #expect(error.code == .capacityExceeded)
        } catch {
            Issue.record("unexpected registration error: \(error)")
        }
        #expect(runtime.actionCount == 0)
        #expect(runtime.state.activeObjects == 1)
    }

    @Test("registered actors receive typed IO values after association")
    func typedDelivery() throws {
        let sourceID = typedIoID("00000000-0000-4000-8000-000000000051")
        let actorID = typedIoID("00000000-0000-4000-8000-000000000052")
        var runtime = StaticRuntimeESP32C6(
            registryID: typedIoID("00000000-0000-4000-8000-000000000050")
        )
        let source = try runtime.registerIoSource(
            metadata: typedSourceMetadata(#"{"objectId":"00000000-0000-4000-8000-000000000051","objectType":"coaty.IoSource","coreType":"IoSource","name":"delivery-source","valueType":"com.example.bool"}"#),
            as: Bool.self
        )
        _ = runtime.drain { _ in }
        _ = try runtime.registerIoActor(
            metadata: typedActorMetadata(#"{"objectId":"00000000-0000-4000-8000-000000000052","objectType":"coaty.IoActor","coreType":"IoActor","name":"delivery-actor","valueType":"com.example.bool"}"#),
            handler: StaticIoHandler(TypedBoolHandler.self, context: 17)
        )
        _ = runtime.drain { _ in }

        let associatePayload = #"{"ioSourceId":"00000000-0000-4000-8000-000000000051","ioActorId":"00000000-0000-4000-8000-000000000052","associatingRoute":"coaty/io-typed","updateRate":0}"#
        let associate = withStaticInbound(
            topic: "coaty/3/test/ASC/00000000-0000-4000-8000-000000000051",
            payload: associatePayload
        ) { topic, payload in
            runtime.receive(topic: topic, payload: payload, nowMS: 40)
        }
        #expect(associate == .accepted)
        _ = runtime.drain { _ in }
        #expect(try runtime.ioAssociationState(of: source).hasAssociations)
        let associationState = try runtime.ioAssociationState(of: source)
        var visitedGeneration: UInt32?
        #expect(try runtime.visitIoAssociationState(of: source, after: 0) { state in
            visitedGeneration = state.generation
        })
        #expect(visitedGeneration == associationState.generation)
        #expect(try runtime.visitIoAssociationState(of: source, after: associationState.generation) { _ in
            Issue.record("unchanged association generation was visited")
        } == false)

        let inbound = withStaticInbound(
            topic: "coaty/3/test/IOV/00000000-0000-4000-8000-000000000051",
            payload: "true"
        ) { topic, payload in
            runtime.receive(topic: topic, payload: payload, nowMS: 77)
        }
        #expect(inbound == .accepted)
        #expect(runtime.actionCount == 1)
        _ = runtime.drain { _ in }
        #expect(typedIoReceipt?.0 == 17)
        #expect(typedIoReceipt?.1 == true)
        #expect(typedIoReceipt?.2 == 77)
        #expect(typedIoReceipt?.4 == .coaty)
        #expect(typedIoReceipt?.3 == runtime.state.generation)
        #expect(source.id == sourceID)
        #expect(actorID != source.id)
    }

    @Test("latest publication retains one replacement until flush")
    func latestPublicationAndFlush() throws {
        var runtime = StaticRuntimeESP32C6(
            registryID: typedIoID("00000000-0000-4000-8000-000000000060")
        )
        let source = try runtime.registerIoSource(
            metadata: typedSourceMetadata(#"{"objectId":"00000000-0000-4000-8000-000000000061","objectType":"coaty.IoSource","coreType":"IoSource","name":"latest-source","valueType":"com.example.bool"}"#),
            as: Bool.self,
            publication: .latest(atMostEveryMS: 50)
        )
        _ = runtime.drain { _ in }
        _ = try runtime.registerIoActor(
            metadata: typedActorMetadata(#"{"objectId":"00000000-0000-4000-8000-000000000062","objectType":"coaty.IoActor","coreType":"IoActor","name":"latest-actor","valueType":"com.example.bool"}"#),
            handler: StaticIoHandler(TypedBoolHandler.self, context: 23)
        )
        _ = runtime.drain { _ in }
        let associatePayload = #"{"ioSourceId":"00000000-0000-4000-8000-000000000061","ioActorId":"00000000-0000-4000-8000-000000000062","associatingRoute":"coaty/io-latest"}"#
        #expect(withStaticInbound(
            topic: "coaty/3/test/ASC/00000000-0000-4000-8000-000000000061",
            payload: associatePayload
        ) { topic, payload in
            runtime.receive(topic: topic, payload: payload, nowMS: 1)
        } == .accepted)
        _ = runtime.drain { _ in }

        #expect(runtime.publishIoValue(true, from: source, nowMS: 100) == .published)
        #expect(runtime.publishIoValue(false, from: source, nowMS: 110) == .queuedLatest)
        #expect(runtime.publishIoValue(true, from: source, nowMS: 120) == .queuedLatest)
        _ = runtime.drain { _ in }
        #expect(runtime.flushIo(nowMS: 120) == 0)
        #expect(runtime.flushIo(nowMS: 150) == 1)
        var payload: [UInt8]?
        _ = runtime.drain { action in
            guard case .publish(let publication) = action.owned() else { return }
            payload = publication.payload
        }
        #expect(payload == Array("true".utf8))
    }

    @Test("dynamic registration fixes representation before publication")
    func dynamicRepresentationMismatch() throws {
        var runtime = StaticRuntimeESP32C6(
            registryID: typedIoID("00000000-0000-4000-8000-000000000070")
        )
        let source = try runtime.registerDynamicIoSource(
            metadata: typedSourceMetadata(#"{"objectId":"00000000-0000-4000-8000-000000000071","objectType":"coaty.IoSource","coreType":"IoSource","name":"dynamic-source","valueType":"com.example.dynamic"}"#),
            representation: .json
        )
        _ = runtime.drain { _ in }
        _ = try runtime.registerDynamicIoActor(
            metadata: typedActorMetadata(#"{"objectId":"00000000-0000-4000-8000-000000000072","objectType":"coaty.IoActor","coreType":"IoActor","name":"dynamic-actor","valueType":"com.example.dynamic"}"#),
            representation: .binary,
            handler: StaticIoHandler(TypedDynamicHandler.self, context: 1)
        )
        _ = runtime.drain { _ in }
        let binaryBytes = try BoundedIoBytes<512>(copying: typedPayload("AB"))
        #expect(
            runtime.publishIoValue(
                .binary(binaryBytes),
                from: source,
                nowMS: 1
            ) == .rejected(.malformedPayload)
        )
        let jsonBytes = try BoundedJSONValue<512>(copying: typedPayload("true"))
        #expect(
            runtime.publishIoValue(
                .json(jsonBytes),
                from: source,
                nowMS: 1
            ) == .notAssociated
        )
    }

    @Test("reset clears transport state and explicit replay restores advertisements")
    func resetAndReplayAdvertisement() throws {
        var runtime = StaticRuntimeESP32C6(
            registryID: typedIoID("00000000-0000-4000-8000-000000000080")
        )
        let source = try runtime.registerIoSource(
            metadata: typedSourceMetadata(#"{"objectId":"00000000-0000-4000-8000-000000000081","objectType":"coaty.IoSource","coreType":"IoSource","name":"replay-source","valueType":"com.example.bool"}"#),
            as: Bool.self
        )
        _ = runtime.drain { _ in }
        #expect(runtime.state.activeObjects == 1)
        runtime.resetTransport()
        #expect(runtime.actionCount == 0)
        #expect(runtime.state.activeObjects == 1)
        try runtime.replayIoAdvertisement(for: source)
        #expect(runtime.actionCount == 1)
        _ = runtime.drain { _ in }
        #expect(runtime.state.activeObjects == 1)
    }
}
