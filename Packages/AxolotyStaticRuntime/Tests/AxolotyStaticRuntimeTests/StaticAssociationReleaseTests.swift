// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyStaticRuntime
import AxolotyWire

private func releaseObjectID(_ literal: StaticString) -> ObjectID {
    ObjectID(bytes: ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount))!
}

private func releaseActorMetadata(_ literal: StaticString) throws -> Object<IoActorMetadata> {
    try Object<IoActorMetadata>(decoding: ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount))
}

private func withStaticReleaseInbound<R>(
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

nonisolated(unsafe) private var deadvertiseHandlerCount = 0

@StaticIoActor(Bool.self)
private enum ReleaseBoolHandler {
    static func receive(
        context: UInt32,
        value: borrowing Bool,
        delivery: borrowing IoDeliveryContext
    ) {
        _ = context
        _ = value
        _ = delivery
    }
}

/// A peer that deadvertises an advertised identity is gone. The static runtime
/// must release that peer's Associate slots and report the false IoState to the
/// surviving local actor without dispatching the synthesized release as a
/// second Deadvertise event.
@Suite("Static association release")
struct StaticAssociationReleaseTests {
    @Test("a peer deadvertise releases its association and reports it once")
    func deadvertiseReleasesAssociation() throws {
        let peerSource = "00000000-0000-4000-8000-0000000000d1"
        let localActor = "00000000-0000-4000-8000-0000000000d2"
        let freshSource = "00000000-0000-4000-8000-0000000000d3"
        deadvertiseHandlerCount = 0

        var runtime = try StaticRuntime<2, 2048>(
            registryID: releaseObjectID("00000000-0000-4000-8000-0000000000d0")
        )
        let actor = try runtime.registerIoActor(
            metadata: releaseActorMetadata(
                #"{"objectId":"00000000-0000-4000-8000-0000000000d2","objectType":"coaty.IoActor","coreType":"IoActor","name":"release-actor","valueType":"com.example.bool"}"#
            ),
            handler: StaticIoHandler(ReleaseBoolHandler.self, context: 1),
            recommendedUpdateRateMS: 0
        )
        _ = runtime.drain { _ in }
        _ = try runtime.register(
            selector: .capability(.deadvertise),
            handler: ProtocolHandlerEntry(
                function: { _, _, _, _, _ in deadvertiseHandlerCount += 1 },
                context: 0
            )
        )

        let advertise = withStaticReleaseInbound(
            topic: "coaty/3/release/ADV/\(peerSource)",
            payload: """
            {"object":{"objectId":"\(peerSource)","coreType":"IoSource","objectType":"coaty.IoSource","name":"peer-source"}}
            """
        ) { topic, payload in
            runtime.receive(topic: topic, payload: payload, nowMS: 10)
        }
        #expect(advertise == .accepted)
        _ = runtime.drain { _ in }

        let associate = withStaticReleaseInbound(
            topic: "coaty/3/release/ASC/\(peerSource)",
            payload: """
            {"ioSourceId":"\(peerSource)","ioActorId":"\(localActor)","associatingRoute":"coaty/io-release"}
            """
        ) { topic, payload in
            runtime.receive(topic: topic, payload: payload, nowMS: 20)
        }
        #expect(associate == .accepted)
        _ = runtime.drain { _ in }
        #expect(try runtime.ioAssociationState(of: actor).hasAssociations)

        let deadvertise = withStaticReleaseInbound(
            topic: "coaty/3/release/DAD/\(peerSource)",
            payload: "{\"objectIds\":[\"\(peerSource)\"]}"
        ) { topic, payload in
            runtime.receive(topic: topic, payload: payload, nowMS: 30)
        }
        #expect(deadvertise == .accepted)
        _ = runtime.drain { _ in }

        #expect(runtime.state.activeAssociations == 0)
        #expect(try runtime.ioAssociationState(of: actor).hasAssociations == false)
        #expect(deadvertiseHandlerCount == 1)

        let reusable = withStaticReleaseInbound(
            topic: "coaty/3/release/ASC/\(freshSource)",
            payload: """
            {"ioSourceId":"\(freshSource)","ioActorId":"\(localActor)","associatingRoute":"coaty/io-release"}
            """
        ) { topic, payload in
            runtime.receive(topic: topic, payload: payload, nowMS: 40)
        }
        #expect(reusable == .accepted)
        _ = runtime.drain { _ in }
        #expect(runtime.state.activeAssociations == 1)
        #expect(try runtime.ioAssociationState(of: actor).hasAssociations)
    }
}
