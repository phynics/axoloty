// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyProtocol
import AxolotyObjectModel
import AxolotyWire

private func protocolSlice(_ value: StaticString) -> ByteSlice {
    ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount)
}

@Suite("AxolotyProtocol foundation")
struct ProtocolFoundationTests {
    @Test("exhaustive borrowed actions preserve every owned case")
    func exhaustiveBorrowedOwnedActions() throws {
        let routingKey = try ProtocolRoutingKey(capability: .channel, sourceID: .zero)
        let topic = protocolSlice("coaty/3/test/CHN:fixture/00000000-0000-0000-0000-000000000000")
        let payload = protocolSlice("{\"value\":1}")
        let delivery = BorrowedProtocolDelivery(
            routingKey: routingKey,
            deliveryKey: .channel(protocolSlice("fixture")),
            routeClassification: .coaty,
            topic: topic,
            payload: payload
        )
        let publication = BorrowedProtocolPublication(
            routingKey: routingKey,
            target: .profile(eventTypeFilter: protocolSlice("fixture"), filterKind: .direct),
            payload: payload
        )
        let association = BorrowedIoAssociationTransition(
            delivery: delivery,
            sourceID: .zero,
            actorID: UUID16(bytes: (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            change: .updated,
            route: BorrowedProtocolRouteSnapshot(slice: payload),
            routeClassification: .external
        )
        let external = BorrowedExternalRouteTransition(sourceID: .zero, actorID: .zero, route: topic)

        #expect(BorrowedProtocolAction.deliver(delivery).owned() == .deliver(delivery.owned()))
        #expect(BorrowedProtocolAction.publish(publication).owned() == .publish(publication.owned()))
        #expect(BorrowedProtocolAction.associationChanged(association).owned() == .associationChanged(association.owned()))
        #expect(BorrowedProtocolAction.externalRouteActivated(external).owned() == .externalRouteActivated(external.owned()))
        #expect(BorrowedProtocolAction.externalRouteDeactivated(external).owned() == .externalRouteDeactivated(external.owned()))
    }

    @Test("owned actions copy borrowed bytes before the source scope ends")
    func ownedActionsCopyBorrowedBytes() throws {
        var bytes = Array("payload".utf8)
        let owned: OwnedProtocolAction = bytes.withUnsafeBufferPointer { buffer in
            let slice = ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            let key = try! ProtocolRoutingKey(capability: .channel, sourceID: .zero)
            return BorrowedProtocolAction.deliver(
                BorrowedProtocolDelivery(
                    routingKey: key,
                    deliveryKey: .channel(slice),
                    topic: slice,
                    payload: slice
                )
            ).owned()
        }
        bytes[0] = Character("X").asciiValue!
        guard case .deliver(let delivery) = owned else {
            Issue.record("owned action changed case")
            return
        }
        #expect(delivery.payload == Array("payload".utf8))
        #expect(delivery.topic == Array("payload".utf8))
        #expect(delivery.deliveryKey == .channel(Array("payload".utf8)))
    }

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

        let action = BorrowedProtocolAction.deliver(
            BorrowedProtocolDelivery(routingKey: owned.routingKey, payload: frame.payload)
        )
        guard case .deliver(let ownedAction) = action.owned() else {
            Issue.record("borrowed delivery changed action case")
            return
        }
        #expect(ownedAction.payload == payload)
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

    @Test("protocol owns Coaty object-filter adaptation")
    func coatyFilterAdapterDecodesDirectAndGroupedFilters() throws {
        let directPayload = Array("{\"objectFilter\":{\"conditions\":[\"value\",[7,2]]}}".utf8)
        let groupedPayload = Array("{\"objectFilter\":{\"conditions\":{\"and\":[[\"value\",[7,2]],[\"present\",[9]]]}}}".utf8)
        let directMatched = try directPayload.withUnsafeBufferPointer { buffer -> Bool in
            let query = try QueryWireData(from: WireReader(bytes: buffer.baseAddress!, length: buffer.count))
            let adapter = try CoatyFilterAdapter<64, 8, 8, 256>(query: query)
            let object = try BoundedDynamicObject<128, 4>(decoding: protocolSlice("{\"value\":2,\"present\":null}"))
            return adapter.matches(object: object)
        }
        let groupedMatched = try groupedPayload.withUnsafeBufferPointer { buffer -> Bool in
            let query = try QueryWireData(from: WireReader(bytes: buffer.baseAddress!, length: buffer.count))
            let adapter = try CoatyFilterAdapter<64, 8, 8, 256>(query: query)
            let object = try BoundedDynamicObject<128, 4>(decoding: protocolSlice("{\"value\":2,\"present\":null}"))
            return adapter.matches(object: object)
        }
        #expect(directMatched)
        #expect(groupedMatched)
    }

    @Test("an absent query filter is protocol match-all")
    func coatyFilterAdapterAbsentFilterMatches() throws {
        let payload = Array("{}".utf8)
        let matched = try payload.withUnsafeBufferPointer { buffer -> Bool in
            let query = try QueryWireData(from: WireReader(bytes: buffer.baseAddress!, length: buffer.count))
            let adapter = try CoatyFilterAdapter<16, 2, 2, 64>(query: query)
            let object = try BoundedDynamicObject<128, 4>(decoding: protocolSlice("{\"other\":true}"))
            return adapter.matches(object: object)
        }
        #expect(matched)
    }

    @Test("malformed query filters map to protocol payload errors")
    func coatyFilterAdapterRejectsMalformedFilter() throws {
        let payload = Array("{\"objectFilter\":{\"conditions\":{\"and\":[],\"or\":[]}}}".utf8)
        #expect(throws: ProtocolError.self) {
            try payload.withUnsafeBufferPointer { buffer in
                let query = try QueryWireData(from: WireReader(bytes: buffer.baseAddress!, length: buffer.count))
                _ = try CoatyFilterAdapter<64, 8, 8, 256>(query: query)
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
        // Discover is a multi-response correlation; another valid Resolve is
        // accepted until its deadline expires.
        #expect(duplicate == .accepted)

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
        #expect(!secondBegin)
        let expired = processor.expire(nowMS: 210)
        #expect(expired)
    }

    @Test("discover and query retain active correlations for multi-response flows")
    func multiResponseCorrelations() throws {
        let correlation = UUID16.zero
        var processor = ProtocolProcessor<2>()
        let discover = try ProtocolLocalOperation(
            capability: .discover,
            sourceID: correlation,
            correlationID: correlation,
            payload: protocolSlice("{}"),
            requestTimeoutMS: 100
        )
        var outbound = InlineProtocolActionSink<2>()
        #expect(processor.processOutbound(discover, nowMS: 10, sink: &outbound) == .accepted)
        outbound.removeAll()
        let first = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000", event: "RSV") { frame in
            var sink = InlineProtocolActionSink<2>()
            return processor.processInbound(frame, nowMS: 20, sink: &sink)
        }
        let second = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000", event: "RSV") { frame in
            var sink = InlineProtocolActionSink<2>()
            return processor.processInbound(frame, nowMS: 30, sink: &sink)
        }
        #expect(first == .accepted)
        #expect(second == .accepted)
        #expect(processor.state.pendingCorrelations == 1)

        processor.resetTransport()
        let query = try ProtocolLocalOperation(
            capability: .query,
            sourceID: correlation,
            correlationID: correlation,
            payload: protocolSlice("{}"),
            requestTimeoutMS: 100
        )
        #expect(processor.processOutbound(query, nowMS: 40, sink: &outbound) == .accepted)
        outbound.removeAll()
        let retrieve = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000", event: "RTV") { frame in
            var sink = InlineProtocolActionSink<2>()
            return processor.processInbound(frame, nowMS: 50, sink: &sink)
        }
        let complete = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000", event: "CPL") { frame in
            var sink = InlineProtocolActionSink<2>()
            return processor.processInbound(frame, nowMS: 60, sink: &sink)
        }
        #expect(retrieve == .accepted)
        #expect(complete == .accepted)
        #expect(processor.state.pendingCorrelations == 0)
    }

    @Test("response families cannot cross request correlation policies")
    func responseFamilyMismatch() throws {
        let correlation = UUID16.zero
        var processor = ProtocolProcessor<1>()
        let operation = try ProtocolLocalOperation(
            capability: .call,
            sourceID: correlation,
            correlationID: correlation,
            payload: protocolSlice("{}"),
            requestTimeoutMS: 100
        )
        var sink = InlineProtocolActionSink<1>()
        #expect(processor.processOutbound(operation, nowMS: 10, sink: &sink) == .accepted)
        sink.removeAll()
        let wrong = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000", event: "RSV") { frame in
            var responseSink = InlineProtocolActionSink<1>()
            return processor.processInbound(frame, nowMS: 20, sink: &responseSink)
        }
        #expect(wrong == .rejected(.correlationMismatch))
        #expect(processor.state.pendingCorrelations == 1)
    }

    @Test("response DTOs reject payloads missing required fields")
    func responsePayloadSchemaIsEnforced() throws {
        let correlation = UUID16.zero
        var processor = ProtocolProcessor<1>()
        let operation = try ProtocolLocalOperation(
            capability: .discover,
            sourceID: correlation,
            correlationID: correlation,
            payload: protocolSlice("{}"),
            requestTimeoutMS: 100
        )
        var sink = InlineProtocolActionSink<1>()
        #expect(processor.processOutbound(operation, nowMS: 10, sink: &sink) == .accepted)
        sink.removeAll()
        let malformed = try withResponseFrame(
            correlation: "00000000-0000-0000-0000-000000000000",
            event: "RSV",
            payload: "{}"
        ) { frame in
            var responseSink = InlineProtocolActionSink<1>()
            return processor.processInbound(frame, nowMS: 20, sink: &responseSink)
        }
        #expect(malformed == .rejected(.malformedPayload))
        #expect(processor.state.pendingCorrelations == 1)
    }

    @Test("cancellation rejects a late response and permits another correlation")
    func cancellation() throws {
        let first = UUID16.zero
        let second = UUID16(bytes: (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        var processor = ProtocolProcessor<1>()
        let operation = try ProtocolLocalOperation(
            capability: .discover,
            sourceID: first,
            correlationID: first,
            payload: protocolSlice("{}"),
            requestTimeoutMS: 100
        )
        var sink = InlineProtocolActionSink<1>()
        #expect(processor.processOutbound(operation, nowMS: 10, sink: &sink) == .accepted)
        sink.removeAll()
        let cancelled = processor.cancel(correlationID: first)
        #expect(cancelled)
        let late = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000", event: "RSV") { frame in
            var responseSink = InlineProtocolActionSink<1>()
            return processor.processInbound(frame, nowMS: 20, sink: &responseSink)
        }
        #expect(late == .rejected(.duplicate))
        let next = try ProtocolLocalOperation(
            capability: .discover,
            sourceID: second,
            correlationID: second,
            payload: protocolSlice("{}"),
            requestTimeoutMS: 100
        )
        #expect(processor.processOutbound(next, nowMS: 20, sink: &sink) == .accepted)
    }

    @Test("transport reset retains local advertisements for one replay")
    func localAdvertisementReplay() throws {
        let source = UUID16.zero
        let payload = protocolSlice("{\"object\":{}}")
        let advertise = try ProtocolLocalOperation(
            capability: .advertise,
            sourceID: source,
            payload: payload
        )
        var processor = ProtocolProcessor<1>()
        var sink = InlineProtocolActionSink<1>()
        #expect(processor.processOutbound(advertise, sink: &sink) == .accepted)
        sink.removeAll()
        processor.resetTransport()
        #expect(processor.state.activeObjects == 1)
        #expect(processor.processOutbound(advertise, sink: &sink) == .accepted)
        sink.removeAll()
        #expect(processor.processOutbound(advertise, sink: &sink) == .rejected(.duplicate))
        #expect(processor.state.activeObjects == 1)
    }
}

private func withStaticPayload<R>(_ body: (ByteSlice) -> R) -> R {
    let payload: StaticString = "{}"
    return body(ByteSlice(bytes: payload.utf8Start, length: payload.utf8CodeUnitCount))
}

private func withResponseFrame<R>(
    correlation: String,
    event: String = "RSV",
    payload explicitPayload: String? = nil,
    _ body: (BorrowedProtocolFrame) throws -> R
) throws -> R {
    let topic = Array("coaty/3/test/\(event)/00000000-0000-0000-0000-000000000000/\(correlation)".utf8)
    let payloadString: String
    if let explicitPayload {
        payloadString = explicitPayload
    } else {
        switch event {
        case "RSV": payloadString = "{\"object\":{}}"
        case "RTV": payloadString = "{\"objects\":[]}"
        case "UPD": payloadString = "{\"object\":{}}"
        default: payloadString = "{}"
        }
    }
    let payload = Array(payloadString.utf8)
    return try topic.withUnsafeBufferPointer { topicBuffer in
        try payload.withUnsafeBufferPointer { payloadBuffer in
            let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
            let bytes = ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
            return try body(try BorrowedProtocolFrame(topic: view, payload: bytes))
        }
    }
}
