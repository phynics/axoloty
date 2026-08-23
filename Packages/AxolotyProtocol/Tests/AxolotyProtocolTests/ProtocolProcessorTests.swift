// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyProtocol
import AxolotyWire

@Suite("Shared fixed-inline protocol processor")
struct ProtocolProcessorTests {
    private static let source = UUID16(bytes: (
        0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
    ))

    @Test("accepted capacity presets remain explicit")
    func capacityPresets() {
        #expect(ProtocolBufferConfig.Preset.tiny == 1)
        #expect(ProtocolBufferConfig.Preset.esp32C6Static == 16)
        #expect(ProtocolBufferConfig.Preset.hostDefault == 64)
    }

    @Test("sink preflight makes saturation atomic")
    func sinkSaturationIsAtomic() throws {
        var processor = ProtocolProcessor<1>()
        var sink = InlineProtocolActionSink<1>()
        let occupiedBytes: StaticString = "{}"
        let occupied = ByteSlice(bytes: occupiedBytes.utf8Start, length: occupiedBytes.utf8CodeUnitCount)
        let occupiedKey = try ProtocolRoutingKey(capability: .channel, sourceID: Self.source)
        let occupiedAppend = sink.append(BorrowedProtocolAction(kind: .deliver, routingKey: occupiedKey, payload: occupied))
        #expect(occupiedAppend)
        let payload = Array("{\"object\":{}}".utf8)
        let outcome = try payload.withUnsafeBufferPointer { buffer in
            let bytes = ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            let operation = try ProtocolLocalOperation(
                capability: .advertise, sourceID: Self.source, payload: bytes
            )
            return processor.processOutbound(operation, sink: &sink)
        }
        #expect(outcome == .rejected(.capacityExceeded))
        #expect(processor.state.activeRecords == 0)
        #expect(sink.count == 1)
    }

    @Test("subscription tokens reject stale generations and inactive entries")
    func subscriptionGenerationAndActivity() throws {
        let callback: ProtocolHandlerFunction = { _, _, _, _, _ in }
        var registry = ProtocolSubscriptionRegistry<1>()
        let token = try registry.register(
            selector: .capability(.advertise),
            handler: ProtocolHandlerEntry(function: callback, context: 7)
        )
        let removed = registry.unregister(token)
        #expect(removed == .removed)
        let replacement = try registry.register(
            selector: .capability(.advertise),
            handler: ProtocolHandlerEntry(function: callback, context: 8)
        )
        let stale = registry.unregister(token)
        let removedReplacement = registry.unregister(replacement)
        let inactive = registry.unregister(replacement)
        #expect(stale == .stale)
        #expect(removedReplacement == .removed)
        #expect(inactive == .inactive)
    }

    @Test("selector matching stays typed and bounded")
    func selectorMatching() throws {
        let callback: ProtocolHandlerFunction = { _, _, _, _, _ in }
        let filter: StaticString = "coaty.test.Sensor"
        let filterSlice = ByteSlice(bytes: filter.utf8Start, length: filter.utf8CodeUnitCount)
        let payloadText: StaticString = "{}"
        let payload = ByteSlice(bytes: payloadText.utf8Start, length: payloadText.utf8CodeUnitCount)
        let routingKey = try ProtocolRoutingKey(capability: .advertise, sourceID: Self.source)
        let action = BorrowedProtocolAction(
            kind: .deliver,
            routingKey: routingKey,
            payload: payload,
            deliveryKey: .advertiseFilter(filterSlice)
        )
        var registry = ProtocolSubscriptionRegistry<2>()
        _ = try registry.register(
            selector: .advertise,
            key: filterSlice,
            handler: ProtocolHandlerEntry(function: callback, context: 1)
        )
        _ = try registry.register(
            selector: .capability(.advertise),
            handler: ProtocolHandlerEntry(function: callback, context: 2)
        )
        let delivered = registry.dispatch(action)
        #expect(delivered == .delivered)

        let otherKey = try ProtocolRoutingKey(capability: .channel, sourceID: Self.source)
        let otherAction = BorrowedProtocolAction(kind: .deliver, routingKey: otherKey, payload: payload)
        let mismatch = registry.dispatch(otherAction)
        #expect(mismatch == .mismatch)
    }

    @Test("registration rejects inactive handlers and fixed-table overflow")
    func subscriptionBounds() throws {
        let callback: ProtocolHandlerFunction = { _, _, _, _, _ in }
        var registry = ProtocolSubscriptionRegistry<1>()
        let inactive = try? registry.register(
            selector: .capability(.channel),
            handler: ProtocolHandlerEntry(function: callback, context: 1, active: false)
        )
        #expect(inactive == nil)
        _ = try registry.register(
            selector: .capability(.channel),
            handler: ProtocolHandlerEntry(function: callback, context: 2)
        )
        let overflow = try? registry.register(
            selector: .capability(.channel),
            handler: ProtocolHandlerEntry(function: callback, context: 3)
        )
        #expect(overflow == nil)
    }

    @Test("binding classifier accepts the exact external route and omits the flag")
    func externalRouteClassification() throws {
        let classifier = ExactProtocolRouteClassifier(
            externalRoute: "external/wire-compat-v1/io-external-1"
        )
        let route = Array("external/wire-compat-v1/io-external-1".utf8)
        let topic = Array("coaty/3/test/ASC/00000000-0000-0000-0000-000000000001".utf8)
        let payload = Array("{\"ioSourceId\":\"00000000-0000-0000-0000-000000000001\",\"ioActorId\":\"00000000-0000-0000-0000-000000000002\",\"associatingRoute\":\"external/wire-compat-v1/io-external-1\"}".utf8)
        var processor = ProtocolProcessor<1>()
        var sink = InlineProtocolActionSink<1>()
        let result = try topic.withUnsafeBufferPointer { topicBuffer in
            try payload.withUnsafeBufferPointer { payloadBuffer in
                let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
                let bytes = ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
                _ = route.withUnsafeBufferPointer { routeBuffer in
                    classifier.classify(ByteSlice(bytes: routeBuffer.baseAddress!, length: routeBuffer.count))
                }
                return processor.processInbound(
                    try BorrowedProtocolFrame(topic: view, payload: bytes),
                    nowMS: 1,
                    classifier: classifier,
                    sink: &sink
                )
            }
        }
        #expect(result == .accepted)
        #expect(processor.state.activeAssociations == 1)
        #expect(sink.count == 1)
    }

    @Test("one actor retains multiple source routes until final detach")
    func multipleSourceAssociationLifetime() throws {
        let sourceOne = "00000000-0000-4000-8000-000000000001"
        let sourceTwo = "00000000-0000-4000-8000-000000000003"
        let actor = "00000000-0000-4000-8000-000000000002"
        var processor = ProtocolProcessor<4>()
        let classifier = ExactProtocolRouteClassifier(externalRoute: "external/wire-compat-v1/io-external-1")
        let first = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(sourceOne)",
            payload: "{\"ioSourceId\":\"\(sourceOne)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"coaty/source-one\"}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(frame, nowMS: 1, classifier: classifier, sink: &sink)
        }
        #expect(first == .accepted)

        let second = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(sourceTwo)",
            payload: "{\"ioSourceId\":\"\(sourceTwo)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"coaty/source-two\"}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(frame, nowMS: 2, classifier: classifier, sink: &sink)
        }
        #expect(second == .accepted)
        #expect(processor.state.activeAssociations == 2)

        let partialDetach = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(sourceOne)",
            payload: "{\"ioSourceId\":\"\(sourceOne)\",\"ioActorId\":\"\(actor)\"}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(frame, nowMS: 3, classifier: classifier, sink: &sink)
        }
        #expect(partialDetach == .accepted)
        #expect(processor.state.activeAssociations == 1)

        let finalDetach = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(sourceTwo)",
            payload: "{\"ioSourceId\":\"\(sourceTwo)\",\"ioActorId\":\"\(actor)\"}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(frame, nowMS: 4, classifier: classifier, sink: &sink)
        }
        #expect(finalDetach == .accepted)
        #expect(processor.state.activeAssociations == 0)
    }

    @Test("unrelated associations are classified before a full sink")
    func unrelatedRouteDoesNotMaskCapacity() throws {
        var processor = ProtocolProcessor<1>()
        var sink = InlineProtocolActionSink<1>()
        let payloadText: StaticString = "{}"
        let payload = ByteSlice(bytes: payloadText.utf8Start, length: payloadText.utf8CodeUnitCount)
        let key = try ProtocolRoutingKey(capability: .channel, sourceID: Self.source)
        let appended = sink.append(BorrowedProtocolAction(kind: .deliver, routingKey: key, payload: payload))
        #expect(appended)

        let result = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/00000000-0000-4000-8000-000000000001",
            payload: "{\"ioSourceId\":\"00000000-0000-4000-8000-000000000001\",\"ioActorId\":\"00000000-0000-4000-8000-000000000002\",\"associatingRoute\":\"unrelated\"}"
        ) { frame in
            processor.processInbound(frame, nowMS: 1, classifier: UnrelatedRouteClassifier(), sink: &sink)
        }
        #expect(result == .ignored)
        #expect(sink.count == 1)
        #expect(processor.state.activeAssociations == 0)
    }

    @Test("IoValue accepts both bare JSON and arbitrary borrowed bytes")
    func ioValuePayloadModes() throws {
        let topic = Array("coaty/3/test/IOV/00000000-0000-4000-8000-000000000001".utf8)
        let binary: [UInt8] = [0x00, 0xA5, 0xFF]
        var processor = ProtocolProcessor<2>()
        let binaryResult = try topic.withUnsafeBufferPointer { topicBuffer in
            try binary.withUnsafeBufferPointer { payloadBuffer in
                let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
                let payload = ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
                var sink = InlineProtocolActionSink<1>()
                return processor.processInbound(try BorrowedProtocolFrame(topic: view, payload: payload), nowMS: 1, sink: &sink)
            }
        }
        #expect(binaryResult == .accepted)

        let json = Array("42".utf8)
        let jsonResult = try topic.withUnsafeBufferPointer { topicBuffer in
            try json.withUnsafeBufferPointer { payloadBuffer in
                let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
                let payload = ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
                var sink = InlineProtocolActionSink<1>()
                return processor.processInbound(try BorrowedProtocolFrame(topic: view, payload: payload), nowMS: 2, sink: &sink)
            }
        }
        #expect(jsonResult == .accepted)
    }
}

private struct UnrelatedRouteClassifier: ProtocolRouteClassifier {
    func classify(_: ByteSlice) -> ProtocolRouteClassification { .unrelated }
}

private func withBorrowedFrame<R>(
    topic: String,
    payload: String,
    _ body: (BorrowedProtocolFrame) throws -> R
) throws -> R {
    let topicBytes = Array(topic.utf8)
    let payloadBytes = Array(payload.utf8)
    return try topicBytes.withUnsafeBufferPointer { topicBuffer in
        try payloadBytes.withUnsafeBufferPointer { payloadBuffer in
            let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
            let bytes = ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
            return try body(try BorrowedProtocolFrame(topic: view, payload: bytes))
        }
    }
}
