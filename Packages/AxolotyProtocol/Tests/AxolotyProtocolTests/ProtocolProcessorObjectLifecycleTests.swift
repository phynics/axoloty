// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyProtocol
import AxolotyWire

extension ProtocolProcessorTests {
    @Test("Advertise reserves canonical core and object-type publications atomically")
    func advertiseFiltersAreAtomic() throws {
        let payload = Array(#"{"object":{"objectId":"11111111-1111-4111-8111-111111111111","coreType":"CoatyObject","objectType":"com.coaty.test.WireFixture","name":"wire-fixture"}}"#.utf8)
        try payload.withUnsafeBufferPointer { buffer in
            let operation = try ProtocolLocalOperation(
                capability: .advertise,
                sourceID: Self.source,
                payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            )
            var saturatedProcessor = ProtocolProcessor<1>()
            var saturatedSink = InlineProtocolActionSink<1>()
            #expect(saturatedProcessor.processOutbound(operation, sink: &saturatedSink) == .rejected(.capacityExceeded))
            #expect(saturatedProcessor.state.activeObjects == 0)
            #expect(saturatedSink.count == 0)

            var processor = ProtocolProcessor<1>()
            var sink = InlineProtocolActionSink<2>()
            #expect(processor.processOutbound(operation, sink: &sink) == .accepted)
            let coreAction = try #require(sink[0]).owned()
            let objectAction = try #require(sink[1]).owned()
            guard case .publish(let corePublication) = coreAction,
                  case .profile(let coreFilter, let coreKind) = corePublication.target,
                  case .publish(let objectPublication) = objectAction,
                  case .profile(let objectFilter, let objectKind) = objectPublication.target else {
                Issue.record("Advertise did not emit profile publications")
                return
            }
            #expect(coreFilter == Array("CoatyObject".utf8))
            #expect(coreKind == .direct)
            #expect(objectFilter == Array("com.coaty.test.WireFixture".utf8))
            #expect(objectKind == .objectType)
            #expect(processor.state.activeObjects == 1)
        }
    }

    @Test("Update retains the pinned single core-type publication")
    func updateUsesOnlyCoreTypeFilter() throws {
        let payload = Array(#"{"object":{"objectId":"11111111-1111-4111-8111-111111111111","coreType":"CoatyObject","objectType":"com.coaty.test.WireFixture","name":"updated"}}"#.utf8)
        try payload.withUnsafeBufferPointer { buffer in
            let operation = try ProtocolLocalOperation(
                capability: .update,
                sourceID: Self.source,
                correlationID: Self.source,
                payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count),
                requestTimeoutMS: 100
            )
            var processor = ProtocolProcessor<1>()
            var sink = InlineProtocolActionSink<2>()
            #expect(processor.processOutbound(operation, sink: &sink) == .accepted)
            #expect(sink.count == 1)
            let action = try #require(sink[0]).owned()
            guard case .publish(let publication) = action,
                  case .profile(let filter, let kind) = publication.target else {
                Issue.record("Update did not emit a profile publication")
                return
            }
            #expect(filter == Array("CoatyObject".utf8))
            #expect(kind == .direct)
        }
    }

    @Test("one source can advertise multiple object identities")
    func multipleAdvertisementsPerSource() throws {
        let source = Self.source
        let first = Array("{\"object\":{\"objectId\":\"11111111-1111-4111-8111-111111111111\"}}".utf8)
        let second = Array("{\"object\":{\"objectId\":\"22222222-2222-4222-8222-222222222222\"}}".utf8)
        var processor = ProtocolProcessor<2>()
        var sink = InlineProtocolActionSink<2>()
        for payload in [first, second] {
            let outcome = try payload.withUnsafeBufferPointer { buffer in
                let operation = try ProtocolLocalOperation(
                    capability: .advertise,
                    sourceID: source,
                    payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
                )
                return processor.processOutbound(operation, sink: &sink)
            }
            #expect(outcome == .accepted)
            sink.removeAll()
        }
        let duplicate = try first.withUnsafeBufferPointer { buffer in
            let operation = try ProtocolLocalOperation(
                capability: .advertise,
                sourceID: source,
                payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            )
            return processor.processOutbound(operation, sink: &sink)
        }
        #expect(duplicate == .rejected(.duplicate))
        #expect(processor.state.activeObjects == 2)
    }

    @Test("deadvertise removes every object named by one source atomically")
    func deadvertiseRemovesMultipleObjects() throws {
        let source = Self.source
        let first = Array("{\"object\":{\"objectId\":\"11111111-1111-4111-8111-111111111111\"}}".utf8)
        let second = Array("{\"object\":{\"objectId\":\"22222222-2222-4222-8222-222222222222\"}}".utf8)
        let removal = Array("{\"objectIds\":[\"11111111-1111-4111-8111-111111111111\",\"22222222-2222-4222-8222-222222222222\"]}".utf8)
        var processor = ProtocolProcessor<2>()
        var sink = InlineProtocolActionSink<2>()
        for payload in [first, second] {
            let outcome = try payload.withUnsafeBufferPointer { buffer in
                let operation = try ProtocolLocalOperation(
                    capability: .advertise,
                    sourceID: source,
                    payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
                )
                return processor.processOutbound(operation, sink: &sink)
            }
            #expect(outcome == .accepted)
            sink.removeAll()
        }

        let outcome = try removal.withUnsafeBufferPointer { buffer in
            let operation = try ProtocolLocalOperation(
                capability: .deadvertise,
                sourceID: source,
                payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            )
            return processor.processOutbound(operation, sink: &sink)
        }
        #expect(outcome == .accepted)
        #expect(processor.state.activeObjects == 0)
    }

    @Test("Advertise, Deadvertise, and Associate retain paired atomic transitions")
    func pairedTransitionPlanning() throws {
        let sourceText = "00000000-0000-4000-8000-000000000001"
        let source = try #require(UUID16(parsing: sourceText))
        let objectID = "11111111-1111-4111-8111-111111111111"
        var advertise = "{\"object\":{\"objectId\":\"\(objectID)\"}}"
        var deadvertise = "{\"objectIds\":[\"\(objectID)\"]}"
        var associate = "{\"ioSourceId\":\"\(sourceText)\",\"ioActorId\":\"00000000-0000-4000-8000-000000000002\",\"associatingRoute\":\"coaty/paired\"}"
        var inbound = ProtocolProcessor<2>()
        var outbound = ProtocolProcessor<2>()

        let inboundAdvertise = try withBorrowedFrame(
            topic: "coaty/3/test/ADV/\(sourceText)", payload: advertise
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return inbound.processInbound(.profile(frame), nowMS: 1, sink: &sink)
        }
        let outboundAdvertise = try advertise.withUTF8 { bytes in
            var sink = InlineProtocolActionSink<2>()
            let operation = try ProtocolLocalOperation(
                capability: .advertise,
                sourceID: source,
                payload: ByteSlice(bytes: bytes.baseAddress!, length: bytes.count)
            )
            return outbound.processOutbound(
                operation, sink: &sink
            )
        }
        #expect(inboundAdvertise == .accepted)
        #expect(outboundAdvertise == .accepted)
        #expect(inbound.state.activeObjects == outbound.state.activeObjects)

        let inboundDeadvertise = try withBorrowedFrame(
            topic: "coaty/3/test/DAD/\(sourceText)", payload: deadvertise
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return inbound.processInbound(.profile(frame), nowMS: 2, sink: &sink)
        }
        let outboundDeadvertise = try deadvertise.withUTF8 { bytes in
            var sink = InlineProtocolActionSink<1>()
            let operation = try ProtocolLocalOperation(
                capability: .deadvertise,
                sourceID: source,
                payload: ByteSlice(bytes: bytes.baseAddress!, length: bytes.count)
            )
            return outbound.processOutbound(
                operation, sink: &sink
            )
        }
        #expect(inboundDeadvertise == .accepted)
        #expect(outboundDeadvertise == .accepted)
        #expect(inbound.state.activeObjects == outbound.state.activeObjects)

        let inboundAssociate = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(sourceText)", payload: associate
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return inbound.processInbound(.profile(frame), nowMS: 3, sink: &sink)
        }
        let outboundAssociate = try associate.withUTF8 { bytes in
            var sink = InlineProtocolActionSink<1>()
            let operation = try ProtocolLocalOperation(
                capability: .associate,
                sourceID: source,
                payload: ByteSlice(bytes: bytes.baseAddress!, length: bytes.count)
            )
            return outbound.processOutbound(
                operation, sink: &sink
            )
        }
        #expect(inboundAssociate == .accepted)
        #expect(outboundAssociate == .accepted)
        #expect(inbound.state.activeAssociations == outbound.state.activeAssociations)
    }
}
