// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyStaticRuntime
import AxolotyWire

private func presenceObjectID(_ literal: StaticString) -> ObjectID {
    ObjectID(bytes: ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount))!
}

private func presenceUUID(_ literal: String) -> UUID16 {
    let bytes = Array(literal.utf8)
    return bytes.withUnsafeBufferPointer { buffer in
        UUID16(parsing: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))!
    }
}

private func presenceCBOR(
    _ body: (inout WireWriter) throws -> Void
) throws -> [UInt8] {
    var output = [UInt8](repeating: 0, count: 1_024)
    let length = try output.withUnsafeMutableBufferPointer { buffer throws -> Int in
        var writer = WireCodec(profile: .axoloty1CBOR).writer(
            buffer: buffer.baseAddress!,
            capacity: buffer.count
        )
        try body(&writer)
        return writer.position
    }
    output.removeSubrange(length..<output.count)
    return output
}

private func presenceText(_ writer: inout WireWriter, _ key: StaticString, _ value: String) throws {
    let bytes = Array(value.utf8)
    try bytes.withUnsafeBufferPointer { buffer throws in
        try writer.writeStringField(key, ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
    }
}

private func presenceAdvertisePayload(
    objectID: String,
    leaseMS: Int?,
    ownerEpoch: Int?
) throws -> [UInt8] {
    let object = try presenceCBOR { writer in
        try writer.beginObject()
        try writer.writeUUIDField("objectId", presenceUUID(objectID))
        try writer.writeComma()
        try presenceText(&writer, "coreType", "IoSource")
        try writer.writeComma()
        try presenceText(&writer, "objectType", "coaty.IoSource")
        try writer.writeComma()
        try presenceText(&writer, "name", "static-presence")
        try writer.endObject()
    }
    return try presenceCBOR { writer in
        try writer.beginObject()
        try object.withUnsafeBufferPointer { buffer throws in
            try writer.writeRawField("object", ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
        }
        if let leaseMS {
            try writer.writeComma()
            try writer.writeIntField("leaseMs", leaseMS)
        }
        if let ownerEpoch {
            try writer.writeComma()
            try writer.writeIntField("ownerEpoch", ownerEpoch)
        }
        try writer.endObject()
    }
}

private func presenceReceive(
    _ runtime: inout StaticRuntime<4, 512>,
    topic: String,
    payload: [UInt8],
    nowMS: UInt32
) -> ProtocolProcessOutcome {
    let topicBytes = Array(topic.utf8)
    return topicBytes.withUnsafeBufferPointer { topicBuffer in
        payload.withUnsafeBufferPointer { payloadBuffer in
            runtime.receive(
                topic: ByteSlice(bytes: topicBuffer.baseAddress!, length: topicBuffer.count),
                payload: ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count),
                nowMS: nowMS
            )
        }
    }
}

@Suite("Static presence")
struct StaticPresenceTests {
    private static let peer = "00000000-0000-4000-8000-000000000301"
    private static let other = "00000000-0000-4000-8000-000000000302"

    private func makeRuntime() throws -> StaticRuntime<4, 512> {
        let definition = try StaticRuntimeDefinition<512>(
            registryID: presenceObjectID("00000000-0000-4000-8000-000000000300"),
            wireCodec: WireCodec(profile: .axoloty1CBOR),
            presencePolicy: .enabled
        )
        return StaticRuntime<4, 512>(
            definition: definition,
            routeClassifier: ExactProtocolRouteClassifier(externalRoute: "external/static-none")
        )
    }

    @Test("a leased peer expires through the static caller API")
    func expirePresence() throws {
        var runtime = try makeRuntime()
        let payload = try presenceAdvertisePayload(objectID: Self.peer, leaseMS: 1_000, ownerEpoch: 1)
        #expect(presenceReceive(
            &runtime,
            topic: "axoloty/1/static/ADV/\(Self.peer)",
            payload: payload,
            nowMS: 100
        ) == .accepted)
        _ = runtime.drain { _ in }
        #expect(runtime.state.activeObjects == 1)
        #expect(runtime.expirePresence(nowMS: 1_099) == nil)
        let expired = runtime.expirePresence(nowMS: 1_100)
        #expect(expired?.sourceID == presenceUUID(Self.peer))
        #expect(expired?.objectID == presenceUUID(Self.peer))
        #expect(runtime.state.activeObjects == 0)
    }

    @Test("a same-epoch refresh renews without a retained action")
    func renewPresence() throws {
        var runtime = try makeRuntime()
        let payload = try presenceAdvertisePayload(objectID: Self.peer, leaseMS: 1_000, ownerEpoch: 1)
        #expect(presenceReceive(&runtime, topic: "axoloty/1/static/ADV/\(Self.peer)", payload: payload, nowMS: 100) == .accepted)
        _ = runtime.drain { _ in }
        let generation = runtime.state.generation
        #expect(presenceReceive(&runtime, topic: "axoloty/1/static/ADV/\(Self.peer)", payload: payload, nowMS: 500) == .accepted)
        #expect(runtime.actionCount == 0)
        #expect(runtime.state.generation == generation)
    }

    @Test("suspend retains leased peers and resume re-bases them")
    func suspendAndResume() throws {
        var runtime = try makeRuntime()
        let payload = try presenceAdvertisePayload(objectID: Self.peer, leaseMS: 1_000, ownerEpoch: 1)
        #expect(presenceReceive(&runtime, topic: "axoloty/1/static/ADV/\(Self.peer)", payload: payload, nowMS: 100) == .accepted)
        _ = runtime.drain { _ in }
        runtime.suspendPresence()
        #expect(runtime.state.activeObjects == 1)
        #expect(runtime.expirePresence(nowMS: 100_000) == nil)
        runtime.resumePresence(nowMS: 100_000)
        #expect(runtime.expirePresence(nowMS: 100_999) == nil)
        #expect(runtime.expirePresence(nowMS: 101_000) != nil)
        #expect(runtime.state.activeObjects == 0)
    }

    @Test("hard reset discards a leased peer")
    func hardReset() throws {
        var runtime = try makeRuntime()
        let payload = try presenceAdvertisePayload(objectID: Self.peer, leaseMS: 1_000, ownerEpoch: 1)
        #expect(presenceReceive(&runtime, topic: "axoloty/1/static/ADV/\(Self.peer)", payload: payload, nowMS: 100) == .accepted)
        _ = runtime.drain { _ in }
        runtime.resetTransport()
        #expect(runtime.state.activeObjects == 0)
        #expect(runtime.expirePresence(nowMS: 1_000_000) == nil)
    }

    @Test("a rebooted peer re-advertise is delivered after expiry")
    func reAdvertiseAfterExpiry() throws {
        var runtime = try makeRuntime()
        let payload = try presenceAdvertisePayload(objectID: Self.peer, leaseMS: 1_000, ownerEpoch: 1)
        #expect(presenceReceive(&runtime, topic: "axoloty/1/static/ADV/\(Self.peer)", payload: payload, nowMS: 100) == .accepted)
        _ = runtime.drain { _ in }
        #expect(presenceReceive(&runtime, topic: "axoloty/1/static/ADV/\(Self.peer)", payload: payload, nowMS: 200) == .accepted)
        _ = runtime.drain { _ in }
        #expect(runtime.expirePresence(nowMS: 1_200) != nil)
        #expect(runtime.actionCount == 0)
        #expect(presenceReceive(&runtime, topic: "axoloty/1/static/ADV/\(Self.peer)", payload: payload, nowMS: 1_300) == .accepted)
        #expect(runtime.state.activeObjects == 1)
    }

    @Test("an unleased peer in an enabled runtime never expires")
    func unleasedPeerNeverExpires() throws {
        var runtime = try makeRuntime()
        let payload = try presenceAdvertisePayload(objectID: Self.other, leaseMS: nil, ownerEpoch: nil)
        #expect(presenceReceive(&runtime, topic: "axoloty/1/static/ADV/\(Self.other)", payload: payload, nowMS: 100) == .accepted)
        _ = runtime.drain { _ in }
        #expect(runtime.expirePresence(nowMS: 1_000_000) == nil)
        #expect(runtime.state.activeObjects == 1)
    }

    @Test("presence requires an axoloty/1 definition")
    func constructionRejectsCoatyPresence() throws {
        do {
            _ = try StaticRuntimeDefinition<512>(
                registryID: presenceObjectID("00000000-0000-4000-8000-000000000303"),
                wireCodec: WireCodec(profile: .coaty3JSON),
                presencePolicy: .enabled
            )
            Issue.record("expected presence construction to fail")
        } catch {
            guard case .presence(.unsupportedWireProfile) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test("expiry frees the slot for a new peer")
    func expiryReusesSlot() throws {
        var runtime = try makeRuntime()
        let peer = try presenceAdvertisePayload(objectID: Self.peer, leaseMS: 1_000, ownerEpoch: 1)
        #expect(presenceReceive(&runtime, topic: "axoloty/1/static/ADV/\(Self.peer)", payload: peer, nowMS: 100) == .accepted)
        _ = runtime.drain { _ in }
        #expect(runtime.expirePresence(nowMS: 1_100) != nil)
        let replacement = try presenceAdvertisePayload(objectID: Self.other, leaseMS: 1_000, ownerEpoch: 1)
        #expect(presenceReceive(&runtime, topic: "axoloty/1/static/ADV/\(Self.other)", payload: replacement, nowMS: 200) == .accepted)
        #expect(runtime.state.activeObjects == 1)
    }

    @Test("suspend drops unleased peers and keeps leased ones")
    func suspendDropsUnleasedPeers() throws {
        var runtime = try makeRuntime()
        let leased = try presenceAdvertisePayload(objectID: Self.peer, leaseMS: 1_000, ownerEpoch: 1)
        let unleased = try presenceAdvertisePayload(objectID: Self.other, leaseMS: nil, ownerEpoch: nil)
        #expect(presenceReceive(&runtime, topic: "axoloty/1/static/ADV/\(Self.peer)", payload: leased, nowMS: 100) == .accepted)
        _ = runtime.drain { _ in }
        #expect(presenceReceive(&runtime, topic: "axoloty/1/static/ADV/\(Self.other)", payload: unleased, nowMS: 101) == .accepted)
        _ = runtime.drain { _ in }
        runtime.suspendPresence()
        #expect(runtime.state.activeObjects == 1)
        runtime.suspendPresence()
        #expect(runtime.state.activeObjects == 1)
        runtime.resumePresence(nowMS: 1_000)
        runtime.resumePresence(nowMS: 1_001)
        #expect(runtime.expirePresence(nowMS: 2_000) != nil)
    }

    @Test("presence disabled leaves suspend, expiry, and coaty/3 unchanged")
    func presenceDisabledIsNoOp() throws {
        let definition = try StaticRuntimeDefinition<512>(
            registryID: presenceObjectID("00000000-0000-4000-8000-000000000304")
        )
        var runtime = StaticRuntime<4, 512>(
            definition: definition,
            routeClassifier: ExactProtocolRouteClassifier(externalRoute: "external/static-none")
        )
        let payload = """
        {"object":{"objectId":"\(Self.peer)","coreType":"IoSource","objectType":"coaty.IoSource","name":"json"},"leaseMs":1000,"ownerEpoch":1}
        """
        let topicBytes = Array("coaty/3/static/ADV/\(Self.peer)".utf8)
        let payloadBytes = Array(payload.utf8)
        let outcome = topicBytes.withUnsafeBufferPointer { topicBuffer in
            payloadBytes.withUnsafeBufferPointer { payloadBuffer in
                runtime.receive(
                    topic: ByteSlice(bytes: topicBuffer.baseAddress!, length: topicBuffer.count),
                    payload: ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count),
                    nowMS: 100
                )
            }
        }
        #expect(outcome == .accepted)
        let actionsBefore = runtime.actionCount
        runtime.suspendPresence()
        #expect(runtime.actionCount == actionsBefore)
        #expect(runtime.state.activeObjects == 1)
        #expect(runtime.expirePresence(nowMS: 1_000_000) == nil)
    }

    @Test("suspend releases the retained action batch")
    func suspendReleasesBatch() throws {
        var runtime = try makeRuntime()
        let payload = try presenceAdvertisePayload(objectID: Self.peer, leaseMS: 1_000, ownerEpoch: 1)
        let payloadBytes = payload
        let outcome = payloadBytes.withUnsafeBufferPointer { buffer in
            runtime.send(
                .advertise(
                    sourceID: presenceUUID(Self.peer),
                    payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
                ),
                nowMS: 100
            )
        }
        #expect(outcome == .accepted)
        #expect(runtime.actionCount > 0)
        runtime.suspendPresence()
        #expect(runtime.actionCount == 0)
    }

    @Test("a local leased object never expires and renews after resume")
    func localPresenceSurvivesResume() throws {
        var runtime = try makeRuntime()
        let payload = try presenceAdvertisePayload(objectID: Self.peer, leaseMS: 1_000, ownerEpoch: 1)
        let outcome = payload.withUnsafeBufferPointer { buffer in
            runtime.send(
                .advertise(
                    sourceID: presenceUUID(Self.peer),
                    payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
                ),
                nowMS: 100
            )
        }
        #expect(outcome == .accepted)
        _ = runtime.drain { _ in }
        #expect(runtime.expirePresence(nowMS: 1_000_000) == nil)
        runtime.suspendPresence()
        runtime.resumePresence(nowMS: 1_000_000)
        let renew = payload.withUnsafeBufferPointer { buffer in
            runtime.send(
                .advertise(
                    sourceID: presenceUUID(Self.peer),
                    payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
                ),
                nowMS: 1_000_100
            )
        }
        #expect(renew == .accepted)
        #expect(runtime.state.activeObjects == 1)
    }
}
