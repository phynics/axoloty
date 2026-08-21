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
        var sink = InlineProtocolActionSink<0>()
        let payload = Array("{}".utf8)
        let outcome = try payload.withUnsafeBufferPointer { buffer in
            let bytes = ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            let operation = try ProtocolLocalOperation(
                capability: .advertise, sourceID: Self.source, payload: bytes
            )
            return processor.processOutbound(operation, sink: &sink)
        }
        #expect(outcome == .rejected(.capacityExceeded))
        #expect(processor.state.activeRecords == 0)
        #expect(sink.count == 0)
    }

    @Test("handler tokens reject stale generations and inactive entries")
    func handlerGenerationAndActivity() {
        let callback: @convention(thin) (UInt32) -> Void = { _ in }
        var handlers = ProtocolHandlerTable<1>()
        let token = handlers.register(ProtocolHandlerEntry(function: callback, context: 7))
        #expect(token != nil)
        let dispatched = handlers.dispatch(token!)
        let stale = handlers.dispatch(token! ^ (UInt64(1) << 32))
        let removed = handlers.unregister(token!)
        let afterRemoval = handlers.dispatch(token!)
        #expect(dispatched)
        #expect(!stale)
        #expect(removed)
        #expect(!afterRemoval)
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
}
