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
                    .profile(try BorrowedProtocolFrame(topic: view, payload: bytes)),
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

    @Test("external association fanout retains external route classification")
    func externalAssociationDeliveryClassification() throws {
        let source = "00000000-0000-4000-8000-000000000001"
        let actor = "00000000-0000-4000-8000-000000000002"
        let route = "external/wire-compat-v1/io-external-1"
        let classifier = ExactProtocolRouteClassifier(externalRoute: "external/wire-compat-v1/io-external-1")
        var processor = ProtocolProcessor<2>()

        let establishedAction: OwnedProtocolAction = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"\(route)\"}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            let result = processor.processInbound(.profile(frame), nowMS: 1, classifier: classifier, sink: &sink)
            #expect(result == .accepted)
            return try #require(sink[0]).owned()
        }
        guard case .associationChanged(let transition) = establishedAction else {
            Issue.record("external Associate did not emit an association transition")
            return
        }
        #expect(transition.change == .established)
        #expect(transition.sourceID == UUID16(parsing: source)!)
        #expect(transition.actorID == UUID16(parsing: actor)!)
        #expect(transition.route == Array(route.utf8))
        #expect(transition.routeClassification == .external)
        #expect(transition.delivery.routeClassification == .external)

        let delivered: OwnedProtocolAction = try withBorrowedFrame(
            topic: "coaty/3/test/IOV/\(source)",
            payload: "{\"value\":1}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            let result = processor.processInbound(.profile(frame), nowMS: 2, classifier: classifier, sink: &sink)
            #expect(result == .accepted)
            return try #require(sink[0]).owned()
        }
        guard case .deliver(let delivery) = delivered else {
            Issue.record("external IoValue did not emit a delivery")
            return
        }
        #expect(delivery.routeClassification == .external)
        #expect(delivery.deliveryKey == .ioActor(UUID16(parsing: actor)!))
    }

    @Test("external disassociation flags reject before state mutation")
    func externalDisassociationFlagRejects() throws {
        var processor = ProtocolProcessor<1>()
        var sink = InlineProtocolActionSink<1>()
        let result = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/00000000-0000-4000-8000-000000000001",
            payload: "{\"ioSourceId\":\"00000000-0000-4000-8000-000000000001\",\"ioActorId\":\"00000000-0000-4000-8000-000000000002\",\"isExternalRoute\":true}"
        ) { frame in
            processor.processInbound(
                .profile(frame),
                nowMS: 1,
                classifier: ExactProtocolRouteClassifier(externalRoute: "external/wire-compat-v1/io-external-1"),
                sink: &sink
            )
        }
        #expect(result == .rejected(.externalRouteMismatch))
        #expect(processor.state.activeAssociations == 0)
        #expect(sink.count == 0)
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
            return processor.processInbound(.profile(frame), nowMS: 1, classifier: classifier, sink: &sink)
        }
        #expect(first == .accepted)

        let second = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(sourceTwo)",
            payload: "{\"ioSourceId\":\"\(sourceTwo)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"coaty/source-two\"}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 2, classifier: classifier, sink: &sink)
        }
        #expect(second == .accepted)
        #expect(processor.state.activeAssociations == 2)

        let partialDetach = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(sourceOne)",
            payload: "{\"ioSourceId\":\"\(sourceOne)\",\"ioActorId\":\"\(actor)\"}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 3, classifier: classifier, sink: &sink)
        }
        #expect(partialDetach == .accepted)
        #expect(processor.state.activeAssociations == 1)

        let finalDetach = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(sourceTwo)",
            payload: "{\"ioSourceId\":\"\(sourceTwo)\",\"ioActorId\":\"\(actor)\"}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 4, classifier: classifier, sink: &sink)
        }
        #expect(finalDetach == .accepted)
        #expect(processor.state.activeAssociations == 0)
    }

    @Test("association removal snapshots the route before clearing state")
    func associationRemovalPreservesRoute() throws {
        let source = "00000000-0000-4000-8000-000000000001"
        let actor = "00000000-0000-4000-8000-000000000002"
        let route = "coaty/source-preserved"
        let classifier = ExactProtocolRouteClassifier(externalRoute: "external/unused")
        var processor = ProtocolProcessor<1>()
        var sink = InlineProtocolActionSink<1>()

        let established = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"\(route)\"}"
        ) { frame in
            processor.processInbound(.profile(frame), nowMS: 1, classifier: classifier, sink: &sink)
        }
        #expect(established == .accepted)
        sink.removeAll()

        let updatedRoute = "coaty/source-updated"
        let updatedAction: OwnedProtocolAction = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"\(updatedRoute)\"}"
        ) { frame in
            let result = processor.processInbound(.profile(frame), nowMS: 2, classifier: classifier, sink: &sink)
            #expect(result == .accepted)
            return try #require(sink[0]).owned()
        }
        guard case .associationChanged(let updatedTransition) = updatedAction else {
            Issue.record("Reassociation did not emit an association transition")
            return
        }
        #expect(updatedTransition.change == .updated)
        #expect(updatedTransition.sourceID == UUID16(parsing: source)!)
        #expect(updatedTransition.actorID == UUID16(parsing: actor)!)
        #expect(updatedTransition.route == Array(updatedRoute.utf8))
        #expect(updatedTransition.routeClassification == .coaty)
        #expect(updatedTransition.delivery.routingKey.capability == .associate)
        #expect(updatedTransition.delivery.routeClassification == .coaty)
        sink.removeAll()

        let removedAction: OwnedProtocolAction = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\"}"
        ) { frame in
            let result = processor.processInbound(.profile(frame), nowMS: 2, classifier: classifier, sink: &sink)
            #expect(result == .accepted)
            return try #require(sink[0]).owned()
        }
        guard case .associationChanged(let transition) = removedAction else {
            Issue.record("Disassociation did not emit an association transition")
            return
        }
        #expect(transition.change == .removed)
        #expect(transition.sourceID == UUID16(parsing: source))
        #expect(transition.actorID == UUID16(parsing: actor))
        #expect(transition.route == Array(updatedRoute.utf8))
        #expect(transition.routeClassification == .coaty)
    }

    @Test("unrelated associations are classified before a full sink")
    func unrelatedRouteDoesNotMaskCapacity() throws {
        var processor = ProtocolProcessor<1>()
        var sink = InlineProtocolActionSink<1>()
        let payloadText: StaticString = "{}"
        let payload = ByteSlice(bytes: payloadText.utf8Start, length: payloadText.utf8CodeUnitCount)
        let key = try ProtocolRoutingKey(capability: .channel, sourceID: Self.source)
        let appended = sink.append(.deliver(BorrowedProtocolDelivery(routingKey: key, payload: payload)))
        #expect(appended)

        let result = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/00000000-0000-4000-8000-000000000001",
            payload: "{\"ioSourceId\":\"00000000-0000-4000-8000-000000000001\",\"ioActorId\":\"00000000-0000-4000-8000-000000000002\",\"associatingRoute\":\"unrelated\"}"
        ) { frame in
            processor.processInbound(.profile(frame), nowMS: 1, classifier: UnrelatedRouteClassifier(), sink: &sink)
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
                return processor.processInbound(.profile(try BorrowedProtocolFrame(topic: view, payload: payload)), nowMS: 1, sink: &sink)
            }
        }
        #expect(binaryResult == .accepted)

        let json = Array("42".utf8)
        let jsonResult = try topic.withUnsafeBufferPointer { topicBuffer in
            try json.withUnsafeBufferPointer { payloadBuffer in
                let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
                let payload = ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
                var sink = InlineProtocolActionSink<1>()
                return processor.processInbound(.profile(try BorrowedProtocolFrame(topic: view, payload: payload)), nowMS: 2, sink: &sink)
            }
        }
        #expect(jsonResult == .accepted)
    }

    @Test("association lifecycle effects preserve ordered route replacement")
    func associationLifecycleOrdering() throws {
        let source = "00000000-0000-4000-8000-000000000001"
        let actor = "00000000-0000-4000-8000-000000000002"
        let firstRoute = "external/io-a"
        let secondRoute = "external/io-b"
        let classifier = MultiExternalRouteClassifier()
        var processor = ProtocolProcessor<4>()

        try withBorrowedFrame(
            topic: "coaty/3/test/ADV/\(actor)",
            payload: "{\"object\":{\"objectId\":\"\(actor)\",\"coreType\":\"IoActor\",\"objectType\":\"coaty.IoActor\",\"name\":\"actor\"}}"
        ) { frame in
            var sink = InlineProtocolActionSink<2>()
            let operation = try ProtocolLocalOperation(capability: .advertise, sourceID: UUID16(parsing: actor)!, payload: frame.payload)
            #expect(processor.processOutbound(operation, sink: &sink) == .accepted)
        }

        let established = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"\(firstRoute)\",\"updateRate\":500}"
        ) { frame in
            var sink = InlineProtocolActionSink<2>()
            let result = processor.processInbound(.profile(frame), nowMS: 1, classifier: classifier, sink: &sink)
            #expect(result == .accepted)
            return (result, sink[0], sink[1])
        }
        #expect(established.0 == .accepted)
        guard case .associationChanged = established.1,
              case .externalRouteActivated = established.2 else {
            Issue.record("external establishment did not emit association then activation")
            return
        }

        let replaced = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"\(secondRoute)\",\"updateRate\":750}"
        ) { frame in
            var sink = InlineProtocolActionSink<3>()
            let result = processor.processInbound(.profile(frame), nowMS: 2, classifier: classifier, sink: &sink)
            #expect(result == .accepted)
            return (sink[0], sink[1], sink[2])
        }
        guard case .externalRouteDeactivated = replaced.0,
              case .associationChanged = replaced.1,
              case .externalRouteActivated = replaced.2 else {
            Issue.record("external replacement effect order changed")
            return
        }

        let removed = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\"}"
        ) { frame in
            var sink = InlineProtocolActionSink<2>()
            let result = processor.processInbound(.profile(frame), nowMS: 3, classifier: classifier, sink: &sink)
            #expect(result == .accepted)
            return (sink[0], sink[1])
        }
        guard case .externalRouteDeactivated = removed.0,
              case .associationChanged(let transition) = removed.1 else {
            Issue.record("external removal effect order changed")
            return
        }
        #expect(transition.change == .removed)
        #expect(processor.ioAssociationState(forActor: UUID16(parsing: actor)!).hasAssociations == false)
    }

    @Test("duplicate associations are idempotent and rates aggregate by endpoint")
    func associationDuplicateAndStateAggregation() throws {
        let source = "00000000-0000-4000-8000-000000000001"
        let sourceTwo = "00000000-0000-4000-8000-000000000003"
        let actor = "00000000-0000-4000-8000-000000000002"
        var processor = ProtocolProcessor<4>()
        let classifier = MultiExternalRouteClassifier()
        let payload = "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"coaty/io-a\",\"updateRate\":500}"
        var sink = InlineProtocolActionSink<2>()
        let first = try withBorrowedFrame(topic: "coaty/3/test/ASC/\(source)", payload: payload) { frame in
            processor.processInbound(.profile(frame), nowMS: 1, classifier: classifier, sink: &sink)
        }
        #expect(first == .accepted)
        let generation = processor.state.generation
        sink.removeAll()
        let duplicate = try withBorrowedFrame(topic: "coaty/3/test/ASC/\(source)", payload: payload) { frame in
            processor.processInbound(.profile(frame), nowMS: 2, classifier: classifier, sink: &sink)
        }
        #expect(duplicate == .ignored)
        #expect(sink.count == 0)
        #expect(processor.state.generation == generation)

        let secondPayload = "{\"ioSourceId\":\"\(sourceTwo)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"coaty/io-b\",\"updateRate\":800}"
        let second = try withBorrowedFrame(topic: "coaty/3/test/ASC/\(sourceTwo)", payload: secondPayload) { frame in
            processor.processInbound(.profile(frame), nowMS: 3, classifier: classifier, sink: &sink)
        }
        #expect(second == .accepted)
        let actorState = processor.ioAssociationState(forActor: UUID16(parsing: actor)!)
        #expect(actorState.associationCount == 2)
        #expect(actorState.recommendedUpdateRateMS == 800)
        #expect(processor.ioAssociationState(forSource: UUID16(parsing: source)!).recommendedUpdateRateMS == 500)
    }

    @Test("association rates and external flags validate without mutation")
    func associationRateValidationAndFlagConsistency() throws {
        let source = "00000000-0000-4000-8000-000000000001"
        let actor = "00000000-0000-4000-8000-000000000002"
        var processor = ProtocolProcessor<2>()
        let classifier = MultiExternalRouteClassifier()

        let zeroRate = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"coaty/zero\",\"isExternalRoute\":false,\"updateRate\":0}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 1, classifier: classifier, sink: &sink)
        }
        #expect(zeroRate == .accepted)
        #expect(processor.ioAssociationState(forSource: UUID16(parsing: source)!).recommendedUpdateRateMS == 0)

        let omittedFlag = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"coaty/zero\",\"updateRate\":1}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 2, classifier: classifier, sink: &sink)
        }
        #expect(omittedFlag == .accepted)

        let noRate = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"coaty/zero\"}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 3, classifier: classifier, sink: &sink)
        }
        #expect(noRate == .accepted)
        #expect(processor.ioAssociationState(forSource: UUID16(parsing: source)!).recommendedUpdateRateMS == nil)

        let beforeInvalid = processor.state
        let negative = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"coaty/negative\",\"updateRate\":-1}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 4, classifier: classifier, sink: &sink)
        }
        #expect(negative == .rejected(.malformedPayload))
        #expect(processor.state == beforeInvalid)

        let overflow = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"coaty/overflow\",\"updateRate\":4294967296}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 5, classifier: classifier, sink: &sink)
        }
        #expect(overflow == .rejected(.malformedPayload))
        #expect(processor.state == beforeInvalid)

        let contradictoryCoaty = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"coaty/contradictory\",\"isExternalRoute\":true}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 6, classifier: classifier, sink: &sink)
        }
        #expect(contradictoryCoaty == .rejected(.externalRouteMismatch))
        #expect(processor.state == beforeInvalid)

        let contradictoryExternal = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"external/io-a\",\"isExternalRoute\":false}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 7, classifier: classifier, sink: &sink)
        }
        #expect(contradictoryExternal == .rejected(.externalRouteMismatch))
        #expect(processor.state == beforeInvalid)

        let maxRate = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"external/io-a\",\"isExternalRoute\":true,\"updateRate\":4294967295}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 8, classifier: classifier, sink: &sink)
        }
        #expect(maxRate == .accepted)
        #expect(processor.ioAssociationState(forSource: UUID16(parsing: source)!).recommendedUpdateRateMS == UInt32.max)
    }

    @Test("outbound IoValue deduplicates exact association routes")
    func outboundIoValueRouteDeduplication() throws {
        let source = "00000000-0000-4000-8000-000000000001"
        let actorOne = "00000000-0000-4000-8000-000000000002"
        let actorTwo = "00000000-0000-4000-8000-000000000003"
        var processor = ProtocolProcessor<4>()
        let classifier = MultiExternalRouteClassifier()
        for (actor, route) in [(actorOne, "coaty/shared"), (actorTwo, "coaty/shared"), ("00000000-0000-4000-8000-000000000004", "coaty/distinct")] {
            let payload = "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"\(route)\"}"
            try withBorrowedFrame(topic: "coaty/3/test/ASC/\(source)", payload: payload) { frame in
                var sink = InlineProtocolActionSink<1>()
                #expect(processor.processInbound(.profile(frame), nowMS: 1, classifier: classifier, sink: &sink) == .accepted)
            }
        }
        let value = Array("{\"value\":1}".utf8)
        try value.withUnsafeBufferPointer { buffer in
            let operation = try ProtocolLocalOperation(
                capability: .ioValue,
                sourceID: UUID16(parsing: source)!,
                payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            )
            var sink = InlineProtocolActionSink<2>()
            #expect(processor.processOutbound(operation, sink: &sink) == .accepted)
            guard case .publish(let first) = try #require(sink[0]).owned(),
                  case .associationRoute(let firstRoute, _) = first.target,
                  case .publish(let second) = try #require(sink[1]).owned(),
                  case .associationRoute(let secondRoute, _) = second.target else {
                Issue.record("IoValue did not publish association routes")
                return
            }
            #expect(firstRoute == Array("coaty/shared".utf8))
            #expect(secondRoute == Array("coaty/distinct".utf8))
            #expect(first.isApplicationDelivery)
            #expect(!second.isApplicationDelivery)
        }
    }

    @Test("external ingress reaches only active local actors")
    func externalIngressTargetsLocalActors() throws {
        let source = "00000000-0000-4000-8000-000000000001"
        let actor = "00000000-0000-4000-8000-000000000002"
        let route = "external/io-a"
        var processor = ProtocolProcessor<2>()
        let classifier = MultiExternalRouteClassifier()
        try withBorrowedFrame(
            topic: "coaty/3/test/ADV/\(actor)",
            payload: "{\"object\":{\"objectId\":\"\(actor)\",\"coreType\":\"IoActor\",\"objectType\":\"coaty.IoActor\",\"name\":\"actor\"}}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            let operation = try ProtocolLocalOperation(capability: .advertise, sourceID: UUID16(parsing: actor)!, payload: frame.payload)
            #expect(processor.processOutbound(operation, sink: &sink) == .accepted)
        }
        try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"\(route)\"}"
        ) { frame in
            var sink = InlineProtocolActionSink<2>()
            #expect(processor.processInbound(.profile(frame), nowMS: 1, classifier: classifier, sink: &sink) == .accepted)
        }
        try withBorrowedBytes(route) { routeBytes in
            try withBorrowedBytes("{\"value\":1}") { valueBytes in
                var sink = InlineProtocolActionSink<1>()
                #expect(processor.processInbound(.externalIo(route: routeBytes, payload: valueBytes), nowMS: 2, classifier: classifier, sink: &sink) == .accepted)
                guard case .deliver(let delivery) = try #require(sink[0]).owned() else {
                    Issue.record("external IO did not deliver")
                    return
                }
                #expect(delivery.deliveryKey == .ioActor(UUID16(parsing: actor)!))
                #expect(delivery.routeClassification == .external)
            }
        }
        try withBorrowedBytes("external/late") { lateRoute in
            try withBorrowedBytes("{}") { valueBytes in
                var sink = InlineProtocolActionSink<1>()
                #expect(processor.processInbound(.externalIo(route: lateRoute, payload: valueBytes), nowMS: 3, classifier: classifier, sink: &sink) == .ignored)
                #expect(sink.count == 0)
            }
        }
    }

    @Test("external ingress fans out to local actors and rejects saturation atomically")
    func externalIngressFanoutAndSaturation() throws {
        let source = "00000000-0000-4000-8000-000000000001"
        let actorOne = "00000000-0000-4000-8000-000000000002"
        let actorTwo = "00000000-0000-4000-8000-000000000003"
        let remoteActor = "00000000-0000-4000-8000-000000000004"
        let route = "external/io-a"
        var processor = ProtocolProcessor<4>()
        let classifier = MultiExternalRouteClassifier()

        for actor in [actorOne, actorTwo] {
            try withBorrowedFrame(
                topic: "coaty/3/test/ADV/\(actor)",
                payload: "{\"object\":{\"objectId\":\"\(actor)\",\"coreType\":\"IoActor\",\"objectType\":\"coaty.IoActor\",\"name\":\"actor\"}}"
            ) { frame in
                var sink = InlineProtocolActionSink<1>()
                let operation = try ProtocolLocalOperation(
                    capability: .advertise,
                    sourceID: UUID16(parsing: actor)!,
                    payload: frame.payload
                )
                #expect(processor.processOutbound(operation, sink: &sink) == .accepted)
            }
        }

        for actor in [actorOne, actorTwo, remoteActor] {
            try withBorrowedFrame(
                topic: "coaty/3/test/ASC/\(source)",
                payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"\(route)\"}"
            ) { frame in
                var sink = InlineProtocolActionSink<2>()
                let result = processor.processInbound(.profile(frame), nowMS: 1, classifier: classifier, sink: &sink)
                #expect(result == .accepted)
            }
        }

        let beforeSaturation = processor.state
        try withBorrowedBytes(route) { routeBytes in
            try withBorrowedBytes("{\"value\":1}") { valueBytes in
                var sink = InlineProtocolActionSink<1>()
                let result = processor.processInbound(
                    .externalIo(route: routeBytes, payload: valueBytes),
                    nowMS: 2,
                    classifier: classifier,
                    sink: &sink
                )
                #expect(result == .rejected(.capacityExceeded))
                #expect(sink.count == 0)
                #expect(processor.state == beforeSaturation)
            }
        }

        try withBorrowedBytes(route) { routeBytes in
            try withBorrowedBytes("{\"value\":1}") { valueBytes in
                var sink = InlineProtocolActionSink<2>()
                let result = processor.processInbound(
                    .externalIo(route: routeBytes, payload: valueBytes),
                    nowMS: 3,
                    classifier: classifier,
                    sink: &sink
                )
                #expect(result == .accepted)
                #expect(sink.count == 2)
                guard case .deliver(let first) = try #require(sink[0]).owned(),
                      case .deliver(let second) = try #require(sink[1]).owned() else {
                    Issue.record("external fanout did not emit deliveries")
                    return
                }
                #expect(first.deliveryKey == .ioActor(UUID16(parsing: actorOne)!))
                #expect(second.deliveryKey == .ioActor(UUID16(parsing: actorTwo)!))
            }
        }

        for actor in [actorOne, actorTwo] {
            try withBorrowedFrame(
                topic: "coaty/3/test/ASC/\(source)",
                payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\"}"
            ) { frame in
                var sink = InlineProtocolActionSink<2>()
                #expect(processor.processInbound(.profile(frame), nowMS: 4, classifier: classifier, sink: &sink) == .accepted)
            }
        }
        try withBorrowedBytes(route) { routeBytes in
            try withBorrowedBytes("{\"value\":2}") { valueBytes in
                var sink = InlineProtocolActionSink<1>()
                #expect(processor.processInbound(.externalIo(route: routeBytes, payload: valueBytes), nowMS: 5, classifier: classifier, sink: &sink) == .ignored)
                #expect(sink.count == 0)
            }
        }
        try withBorrowedBytes("external/io-b") { lateRoute in
            try withBorrowedBytes("{\"value\":3}") { valueBytes in
                var sink = InlineProtocolActionSink<1>()
                #expect(processor.processInbound(.externalIo(route: lateRoute, payload: valueBytes), nowMS: 6, classifier: classifier, sink: &sink) == .ignored)
                #expect(sink.count == 0)
            }
        }
    }

    @Test("multi-effect rejection leaves association state and sink unchanged")
    func associationEffectCapacityIsAtomic() throws {
        let source = "00000000-0000-4000-8000-000000000001"
        let actor = "00000000-0000-4000-8000-000000000002"
        var processor = ProtocolProcessor<2>()
        let classifier = MultiExternalRouteClassifier()
        try withBorrowedFrame(
            topic: "coaty/3/test/ADV/\(actor)",
            payload: "{\"object\":{\"objectId\":\"\(actor)\",\"coreType\":\"IoActor\",\"objectType\":\"coaty.IoActor\",\"name\":\"actor\"}}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            let operation = try ProtocolLocalOperation(capability: .advertise, sourceID: UUID16(parsing: actor)!, payload: frame.payload)
            #expect(processor.processOutbound(operation, sink: &sink) == .accepted)
        }
        try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"external/io-a\"}"
        ) { frame in
            var sink = InlineProtocolActionSink<2>()
            #expect(processor.processInbound(.profile(frame), nowMS: 1, classifier: classifier, sink: &sink) == .accepted)
        }
        let before = processor.state
        var sink = InlineProtocolActionSink<3>()
        let key = try ProtocolRoutingKey(capability: .channel, sourceID: Self.source)
        let marker = ByteSlice(bytes: StaticString("{}").utf8Start, length: 2)
        let markerAppended = sink.append(.deliver(BorrowedProtocolDelivery(routingKey: key, payload: marker)))
        #expect(markerAppended)
        let result = try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: "{\"ioSourceId\":\"\(source)\",\"ioActorId\":\"\(actor)\",\"associatingRoute\":\"external/io-b\"}"
        ) { frame in
            processor.processInbound(.profile(frame), nowMS: 2, classifier: classifier, sink: &sink)
        }
        #expect(result == .rejected(.capacityExceeded))
        #expect(sink.count == 1)
        #expect(processor.state == before)
    }
}

private struct UnrelatedRouteClassifier: ProtocolRouteClassifier {
    func classify(_: ByteSlice) -> ProtocolRouteClassification { .unrelated }
}

private struct MultiExternalRouteClassifier: ProtocolRouteClassifier {
    func classify(_ route: ByteSlice) -> ProtocolRouteClassification {
        route.equals("external/io-a") || route.equals("external/io-b") ? .external : .coaty
    }
}

private func withBorrowedBytes<R>(_ value: String, _ body: (ByteSlice) throws -> R) throws -> R {
    let bytes = Array(value.utf8)
    return try bytes.withUnsafeBufferPointer { buffer in
        try body(ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
    }
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
