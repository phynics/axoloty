// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

private func hostPresenceObject(_ objectID: String) throws -> [UInt8] {
    var output = [UInt8](repeating: 0, count: 512)
    let length = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) -> Int in
        var writer = WireCodec(profile: .axoloty1CBOR).writer(
            buffer: buffer.baseAddress!,
            capacity: buffer.count
        )
        try writer.beginObject()
        try writer.writeUUIDField("objectId", UUID16(parsing: objectID)!)
        try writer.writeComma()
        try hostPresenceText(&writer, "coreType", "IoSource")
        try writer.writeComma()
        try hostPresenceText(&writer, "objectType", "coaty.IoSource")
        try writer.writeComma()
        try hostPresenceText(&writer, "name", "host-presence")
        try writer.endObject()
        return writer.position
    }
    output.removeSubrange(length..<output.count)
    return output
}

private func hostPresenceText(_ writer: inout WireWriter, _ key: StaticString, _ value: String) throws(WireEncodeError) {
    let bytes = Array(value.utf8)
    try bytes.withUnsafeBufferPointer { buffer throws(WireEncodeError) in
        try writer.writeStringField(key, ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
    }
}

private func hostPresenceAdvertise(_ object: [UInt8], leaseMS: Int, ownerEpoch: Int) throws -> [UInt8] {
    var output = [UInt8](repeating: 0, count: 1_024)
    let length = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) -> Int in
        var writer = WireCodec(profile: .axoloty1CBOR).writer(
            buffer: buffer.baseAddress!,
            capacity: buffer.count
        )
        try writer.beginObject()
        try object.withUnsafeBufferPointer { objectBuffer throws(WireEncodeError) in
            try writer.writeRawField("object", ByteSlice(bytes: objectBuffer.baseAddress!, length: objectBuffer.count))
        }
        try writer.writeComma()
        try writer.writeIntField("leaseMs", leaseMS)
        try writer.writeComma()
        try writer.writeIntField("ownerEpoch", ownerEpoch)
        try writer.endObject()
        return writer.position
    }
    output.removeSubrange(length..<output.count)
    return output
}

extension AxolotyRuntimeTests {
    private static let hostPresencePeer = "00000000-0000-4000-8000-000000000401"

    @Test("a host leased advertise publishes and refreshes")
    func hostAdvertiseRefreshes() async throws {
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let builder = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "presence",
            presencePolicy: .enabled
        )
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
        try await runtime.start()

        let object = try hostPresenceObject(Self.hostPresencePeer)
        let receipt = await runtime.advertise(
            objectID: UUID16(parsing: Self.hostPresencePeer)!,
            object: object,
            leaseMS: 1_000
        )
        #expect(receipt == .accepted)
        let first = await transport.publications().filter { isAdvertiseRoute($0.route) }
        #expect(first.count == 1)
        #expect(String(decoding: first[0].payload, as: UTF8.self).isEmpty == false)

        // The 1 s lease derives a 1 s minimum refresh interval.
        try await Task.sleep(for: .milliseconds(1_300))
        let refreshed = await transport.publications().filter { isAdvertiseRoute($0.route) }
        #expect(refreshed.count >= 2)
        await runtime.stop()
    }

    @Test("host presence expiry reaches the additive stream")
    func hostPresenceExpiryStream() async throws {
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let builder = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "presence",
            presencePolicy: .enabled
        )
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
        try await runtime.start()
        let expiries = await runtime.presenceExpiries()
        var iterator = expiries.makeAsyncIterator()

        let object = try hostPresenceObject(Self.hostPresencePeer)
        let payload = try hostPresenceAdvertise(object, leaseMS: 1_000, ownerEpoch: 1)
        await transport.deliver(.profile(
            route: "axoloty/1/presence/ADV/\(Self.hostPresencePeer)",
            payload: payload,
            nowMS: 1
        ))

        let expiry = try await nextValue(&iterator, timeout: .seconds(5))
        #expect(expiry.sourceID == UUID16(parsing: Self.hostPresencePeer))
        #expect(expiry.objectID == UUID16(parsing: Self.hostPresencePeer))
        await runtime.stop()
    }

    @Test("a coaty/3 transport rejects an enabled presence runtime")
    func hostPresenceRequiresCBOR() async throws {
        let builder = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "presence",
            presencePolicy: .enabled
        )
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: TestTransport())
        do {
            try await runtime.start()
            Issue.record("expected presence composition to fail")
        } catch let error as AxolotyError {
            guard case .runtime(.notStarted, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
        await runtime.stop()
    }
}
