// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyProtocol
import AxolotyWire

extension ProtocolProcessorTests {
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
        let occupiedAppend = sink.append(.deliver(BorrowedProtocolDelivery(routingKey: occupiedKey, payload: occupied)))
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
        let action = BorrowedProtocolAction.deliver(BorrowedProtocolDelivery(
            routingKey: routingKey,
            deliveryKey: .advertiseFilter(filterSlice),
            payload: payload
        ))
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
        let otherAction = BorrowedProtocolAction.deliver(BorrowedProtocolDelivery(routingKey: otherKey, payload: payload))
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
}
