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
}
