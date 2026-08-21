// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyProtocol
import AxolotyWire

@Suite("AxolotyProtocol foundation")
struct ProtocolFoundationTests {
    @Test("Coaty Core Profile 3 is closed")
    func profileIsClosed() {
        #expect(CoatyCore3Profile.namespace == "coaty")
        #expect(CoatyCore3Profile.version == 3)
        #expect(CoatyCore3Profile.identifier == "coaty/3")
        #expect(CoatyCore3Profile.capabilityCount == 13)
        #expect(CoatyCore3Profile.capabilities.isCoatyCore3)
        #expect(CoatyCore3Profile.capabilities.rawValue == 0x1FFF)
    }

    @Test("Every closed capability maps to exactly one wire event")
    func capabilityMappingIsOneToOne() throws {
        for rawValue in 0..<CoatyCore3Profile.capabilityCount {
            let capability = try #require(ProtocolCapability(rawValue: UInt8(rawValue)))
            let roundTrip = try #require(ProtocolCapability(wireEventType: capability.wireEventType))
            #expect(roundTrip == capability)
            #expect(CoatyCore3Profile.capabilities.contains(capability))
        }
    }

    @Test("routing keys enforce one-way and request-response correlation")
    func routingKeyCorrelationRules() throws {
        let source = UUID16.zero
        let request = try ProtocolRoutingKey(
            capability: .discover,
            sourceID: source,
            correlationID: source
        )
        #expect(request.correlationID == source)
        #expect(throws: ProtocolError.self) {
            try ProtocolRoutingKey(capability: .advertise, sourceID: source, correlationID: source)
        }
        #expect(throws: ProtocolError.self) {
            try ProtocolRoutingKey(capability: .discover, sourceID: source)
        }
    }

    @Test("borrowed frames and actions cross into owned values explicitly")
    func borrowedOwnedBoundary() throws {
        let topic = Array("coaty/3/test/DSC/00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000".utf8)
        let payload = Array("{\"value\":1}".utf8)
        let frame = try topic.withUnsafeBufferPointer { topicBuffer in
            try payload.withUnsafeBufferPointer { payloadBuffer in
                let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
                let bytes = ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
                return try BorrowedProtocolFrame(topic: view, payload: bytes)
            }
        }
        let owned = frame.owned()
        #expect(owned.routingKey.capability == .discover)
        #expect(owned.payload == payload)

        let action = BorrowedProtocolAction(kind: .deliver, routingKey: owned.routingKey, payload: frame.payload)
        #expect(action.owned().payload == payload)
    }

    @Test("raw and malformed topics are rejected before routing")
    func malformedFramesReject() throws {
        let topic = Array("external/wire-compat-v1/io-external-1".utf8)
        let payload = [UInt8]()
        #expect(throws: ProtocolError.self) {
            try topic.withUnsafeBufferPointer { topicBuffer in
                try payload.withUnsafeBufferPointer { payloadBuffer in
                    let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
                    let bytes = ByteSlice(bytes: payloadBuffer.baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!, length: 0)
                    _ = try BorrowedProtocolFrame(topic: view, payload: bytes)
                }
            }
        }
    }

    @Test("bounded request state rejects saturation, stale, and duplicate responses")
    func boundedRequestState() throws {
        let first = UUID16.zero
        let second = UUID16(bytes: (
            0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ))
        var processor = ProtocolProcessor<1>()
        let firstBegin = withStaticPayload { payload in
            let operation = try! ProtocolLocalOperation(
                capability: .discover,
                sourceID: first,
                correlationID: first,
                payload: payload,
                requestTimeoutMS: 50
            )
            var sink = InlineProtocolActionSink<1>()
            return processor.processOutbound(operation, nowMS: 100, sink: &sink) == .accepted
        }
        #expect(firstBegin)
        let saturatedBegin = withStaticPayload { payload in
            let operation = try! ProtocolLocalOperation(
                capability: .discover,
                sourceID: second,
                correlationID: second,
                payload: payload,
                requestTimeoutMS: 50
            )
            var sink = InlineProtocolActionSink<1>()
            return processor.processOutbound(operation, nowMS: 100, sink: &sink) == .accepted
        }
        #expect(!saturatedBegin)

        let wrong = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000001") { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(frame, nowMS: 110, sink: &sink)
        }
        #expect(wrong == .rejected(.correlationMismatch))
        let accepted = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000") { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(frame, nowMS: 149, sink: &sink)
        }
        #expect(accepted == .accepted)
        let duplicate = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000") { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(frame, nowMS: 149, sink: &sink)
        }
        #expect(duplicate == .rejected(.duplicate))

        let secondBegin = withStaticPayload { payload in
            let operation = try! ProtocolLocalOperation(
                capability: .discover,
                sourceID: second,
                correlationID: second,
                payload: payload,
                requestTimeoutMS: 10
            )
            var sink = InlineProtocolActionSink<1>()
            return processor.processOutbound(operation, nowMS: 200, sink: &sink) == .accepted
        }
        #expect(secondBegin)
        let expired = processor.expire(nowMS: 210)
        #expect(expired)
    }
}

private func withStaticPayload<R>(_ body: (ByteSlice) -> R) -> R {
    let payload: StaticString = "{}"
    return body(ByteSlice(bytes: payload.utf8Start, length: payload.utf8CodeUnitCount))
}

private func withResponseFrame<R>(
    correlation: String,
    _ body: (BorrowedProtocolFrame) throws -> R
) throws -> R {
    let topic = Array("coaty/3/test/RTN/00000000-0000-0000-0000-000000000000/\(correlation)".utf8)
    let payload = Array("{}".utf8)
    return try topic.withUnsafeBufferPointer { topicBuffer in
        try payload.withUnsafeBufferPointer { payloadBuffer in
            let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
            let bytes = ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
            return try body(try BorrowedProtocolFrame(topic: view, payload: bytes))
        }
    }
}
