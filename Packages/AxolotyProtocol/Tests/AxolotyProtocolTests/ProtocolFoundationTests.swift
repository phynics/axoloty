// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyProtocol
import AxolotyObjectModel
import AxolotyWire

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

    @Test("owned actions copy every borrowed selector, target, route, and payload")
    func ownedActionsCopyEveryBorrowedByteField() throws {
        var selectorBytes = Array("selector".utf8)
        var topicBytes = Array("coaty/3/test/CHN/fixture".utf8)
        var payloadBytes = Array("payload".utf8)
        var routeBytes = Array("external/fixture".utf8)

        let owned: [OwnedProtocolAction] = selectorBytes.withUnsafeBufferPointer { selectorBuffer in
            topicBytes.withUnsafeBufferPointer { topicBuffer in
                payloadBytes.withUnsafeBufferPointer { payloadBuffer in
                    routeBytes.withUnsafeBufferPointer { routeBuffer in
                        let selector = ByteSlice(bytes: selectorBuffer.baseAddress!, length: selectorBuffer.count)
                        let topic = ByteSlice(bytes: topicBuffer.baseAddress!, length: topicBuffer.count)
                        let payload = ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
                        let route = ByteSlice(bytes: routeBuffer.baseAddress!, length: routeBuffer.count)
                        let routingKey = try! ProtocolRoutingKey(capability: .channel, sourceID: .zero)
                        let delivery = BorrowedProtocolDelivery(
                            routingKey: routingKey,
                            deliveryKey: .channel(selector),
                            routeClassification: .external,
                            topic: topic,
                            payload: payload
                        )
                        let profile = BorrowedProtocolPublication(
                            routingKey: routingKey,
                            target: .profile(eventTypeFilter: selector, filterKind: .direct),
                            payload: payload,
                            isApplicationDelivery: false
                        )
                        let associationPublication = BorrowedProtocolPublication(
                            routingKey: routingKey,
                            target: .associationRoute(route: route, kind: .external),
                            payload: payload
                        )
                        let association = BorrowedIoAssociationTransition(
                            delivery: delivery,
                            sourceID: .zero,
                            actorID: .zero,
                            change: .removed,
                            route: BorrowedProtocolRouteSnapshot(slice: route),
                            routeClassification: .external
                        )
                        let external = BorrowedExternalRouteTransition(
                            sourceID: .zero,
                            actorID: .zero,
                            route: route
                        )
                        let capability = BorrowedProtocolDelivery(
                            routingKey: routingKey,
                            deliveryKey: .capability(.channel),
                            payload: payload
                        )
                        let advertiseFilter = BorrowedProtocolDelivery(
                            routingKey: routingKey,
                            deliveryKey: .advertiseFilter(selector),
                            payload: payload
                        )
                        let actor = BorrowedProtocolDelivery(
                            routingKey: routingKey,
                            deliveryKey: .ioActor(.zero),
                            payload: payload
                        )
                        let correlated = BorrowedProtocolDelivery(
                            routingKey: routingKey,
                            deliveryKey: .correlated(.discover, .zero),
                            payload: payload
                        )
                        return [
                            BorrowedProtocolAction.deliver(delivery).owned(),
                            BorrowedProtocolAction.publish(profile).owned(),
                            BorrowedProtocolAction.associationChanged(association).owned(),
                            BorrowedProtocolAction.externalRouteActivated(external).owned(),
                            BorrowedProtocolAction.externalRouteDeactivated(external).owned(),
                            BorrowedProtocolAction.publish(associationPublication).owned(),
                            BorrowedProtocolAction.deliver(capability).owned(),
                            BorrowedProtocolAction.deliver(advertiseFilter).owned(),
                            BorrowedProtocolAction.deliver(actor).owned(),
                            BorrowedProtocolAction.deliver(correlated).owned()
                        ]
                    }
                }
            }
        }

        selectorBytes[0] = Character("X").asciiValue!
        topicBytes[0] = Character("X").asciiValue!
        payloadBytes[0] = Character("X").asciiValue!
        routeBytes[0] = Character("X").asciiValue!

        guard case .deliver(let delivery) = owned[0],
              case .channel(let deliverySelector) = delivery.deliveryKey,
              case .publish(let publication) = owned[1],
              case .profile(let profileSelector, _) = publication.target,
              case .associationChanged(let association) = owned[2],
              case .externalRouteActivated(let activated) = owned[3],
              case .externalRouteDeactivated(let deactivated) = owned[4],
              case .publish(let externalPublication) = owned[5],
              case .deliver(let capabilityDelivery) = owned[6],
              case .deliver(let advertiseFilterDelivery) = owned[7],
              case .deliver(let actorDelivery) = owned[8],
              case .deliver(let correlatedDelivery) = owned[9] else {
            Issue.record("owned action cases changed during copying")
            return
        }
        #expect(deliverySelector == Array("selector".utf8))
        #expect(delivery.topic == Array("coaty/3/test/CHN/fixture".utf8))
        #expect(delivery.payload == Array("payload".utf8))
        #expect(profileSelector == Array("selector".utf8))
        #expect(publication.payload == Array("payload".utf8))
        #expect(!publication.isApplicationDelivery)
        #expect(association.route == Array("external/fixture".utf8))
        #expect(activated.route == Array("external/fixture".utf8))
        #expect(deactivated.route == Array("external/fixture".utf8))
        guard case .associationRoute(let externalRoute, let routeKind) = externalPublication.target else {
            Issue.record("association publication target changed during copying")
            return
        }
        #expect(externalRoute == Array("external/fixture".utf8))
        #expect(routeKind == .external)
        #expect(capabilityDelivery.deliveryKey == .capability(.channel))
        guard case .advertiseFilter(let advertiseFilterBytes) = advertiseFilterDelivery.deliveryKey,
              case .ioActor(let actorID) = actorDelivery.deliveryKey,
              case .correlated(let correlatedCapability, let correlationID) = correlatedDelivery.deliveryKey else {
            Issue.record("delivery selector cases changed during copying")
            return
        }
        #expect(advertiseFilterBytes == Array("selector".utf8))
        #expect(actorID == .zero)
        #expect(correlatedCapability == .discover)
        #expect(correlationID == .zero)
    }

    @Test("fixed owning sink preserves every action byte after source mutation")
    func inlineOwnedSinkCopiesEveryActionByte() throws {
        var selectorBytes = Array("selector".utf8)
        var topicBytes = Array("coaty/3/test/CHN/fixture".utf8)
        var payloadBytes = Array("payload".utf8)
        var routeBytes = Array("external/fixture".utf8)
        var sink = InlineOwnedProtocolActionSink<10, 512>()
        var expected: [OwnedProtocolAction] = []

        selectorBytes.withUnsafeBufferPointer { selectorBuffer in
            topicBytes.withUnsafeBufferPointer { topicBuffer in
                payloadBytes.withUnsafeBufferPointer { payloadBuffer in
                    routeBytes.withUnsafeBufferPointer { routeBuffer in
                        let selector = ByteSlice(bytes: selectorBuffer.baseAddress!, length: selectorBuffer.count)
                        let topic = ByteSlice(bytes: topicBuffer.baseAddress!, length: topicBuffer.count)
                        let payload = ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
                        let route = ByteSlice(bytes: routeBuffer.baseAddress!, length: routeBuffer.count)
                        let routingKey = try! ProtocolRoutingKey(capability: .channel, sourceID: .zero)
                        let delivery = BorrowedProtocolDelivery(
                            routingKey: routingKey,
                            deliveryKey: .channel(selector),
                            routeClassification: .external,
                            topic: topic,
                            payload: payload
                        )
                        let profile = BorrowedProtocolPublication(
                            routingKey: routingKey,
                            target: .profile(eventTypeFilter: selector, filterKind: .direct),
                            payload: payload,
                            isApplicationDelivery: false
                        )
                        let associationPublication = BorrowedProtocolPublication(
                            routingKey: routingKey,
                            target: .associationRoute(route: route, kind: .external),
                            payload: payload
                        )
                        let association = BorrowedIoAssociationTransition(
                            delivery: delivery,
                            sourceID: .zero,
                            actorID: .zero,
                            change: .removed,
                            route: BorrowedProtocolRouteSnapshot(slice: route),
                            routeClassification: .external
                        )
                        let external = BorrowedExternalRouteTransition(
                            sourceID: .zero,
                            actorID: .zero,
                            route: route
                        )
                        let actions: [BorrowedProtocolAction] = [
                            .deliver(delivery),
                            .publish(profile),
                            .associationChanged(association),
                            .externalRouteActivated(external),
                            .externalRouteDeactivated(external),
                            .publish(associationPublication),
                            .deliver(BorrowedProtocolDelivery(
                                routingKey: routingKey,
                                deliveryKey: .capability(.channel),
                                payload: payload
                            )),
                            .deliver(BorrowedProtocolDelivery(
                                routingKey: routingKey,
                                deliveryKey: .advertiseFilter(selector),
                                payload: payload
                            )),
                            .deliver(BorrowedProtocolDelivery(
                                routingKey: routingKey,
                                deliveryKey: .ioActor(.zero),
                                payload: payload
                            )),
                            .deliver(BorrowedProtocolDelivery(
                                routingKey: routingKey,
                                deliveryKey: .correlated(.discover, .zero),
                                payload: payload
                            )),
                        ]
                        expected = actions.map { $0.owned() }
                        let preflighted = sink.preflight(actionCount: actions.count)
                        #expect(preflighted)
                        for action in actions {
                            let appended = sink.append(action)
                            #expect(appended)
                        }
                    }
                }
            }
        }

        selectorBytes[0] = Character("X").asciiValue!
        topicBytes[0] = Character("X").asciiValue!
        payloadBytes[0] = Character("X").asciiValue!
        routeBytes[0] = Character("X").asciiValue!

        var actual: [OwnedProtocolAction] = []
        for index in 0..<sink.count {
            #expect(sink.visit(at: index) { actual.append($0.owned()) })
        }
        #expect(actual == expected)
    }

    @Test("fixed owning sink preflight and byte bounds are atomic")
    func inlineOwnedSinkSaturationIsAtomic() throws {
        var sink = InlineOwnedProtocolActionSink<1, 512>()
        let saturated = sink.preflight(actionCount: 2)
        #expect(!saturated)
        #expect(sink.count == 0)
        #expect(sink.remainingCapacity == 1)

        var oversized = Array(repeating: UInt8(1), count: 513)
        oversized.withUnsafeBufferPointer { buffer in
            let action = BorrowedProtocolAction.deliver(BorrowedProtocolDelivery(
                routingKey: try! ProtocolRoutingKey(capability: .channel, sourceID: .zero),
                payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            ))
            let preflighted = sink.preflight(actionCount: 1)
            #expect(preflighted)
            let appended = sink.append(action)
            #expect(!appended)
        }
        oversized[0] = 2
        #expect(sink.count == 0)
        sink.removeAll()
        #expect(sink.remainingCapacity == 1)

        var oversizedTopic = Array(repeating: UInt8(0x74), count: WireBufferConfig.maxTopicLength + 1)
        oversizedTopic.withUnsafeBufferPointer { buffer in
            let action = BorrowedProtocolAction.deliver(BorrowedProtocolDelivery(
                routingKey: try! ProtocolRoutingKey(capability: .channel, sourceID: .zero),
                topic: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count),
                payload: protocolSlice("{}")
            ))
            let preflighted = sink.preflight(actionCount: 1)
            #expect(preflighted)
            let appended = sink.append(action)
            #expect(!appended)
        }
        oversizedTopic[0] = 0x78
        #expect(sink.count == 0)
        sink.removeAll()
        #expect(sink.remainingCapacity == 1)
    }

    @Test("processor rejects a payload larger than the owning sink before mutation")
    func processorAndSinkCapacityMismatchIsAtomic() throws {
        let topicBytes = Array("coaty/3/test/IOV/00000000-0000-4000-8000-000000000001".utf8)
        var payloadBytes = [UInt8](repeating: 0x01, count: 65)
        var processor = ProtocolProcessor<1>(maximumPayloadBytes: 512)
        var sink = InlineOwnedProtocolActionSink<1, 64>()

        topicBytes.withUnsafeBufferPointer { topicBuffer in
            payloadBytes.withUnsafeBufferPointer { payloadBuffer in
                let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
                let frame = try! BorrowedProtocolFrame(
                    topic: view,
                    payload: ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
                )
                let outcome = processor.processInbound(.profile(frame), nowMS: 0, sink: &sink)
                #expect(outcome == .rejected(.capacityExceeded))
                #expect(sink.count == 0)
                #expect(processor.state.generation == 0)
            }
        }
        payloadBytes[0] = 0x02
        #expect(sink.remainingCapacity == 1)
    }

    @Test("association route snapshots retain the complete bounded route")
    func routeSnapshotBounds() throws {
        let routeBytes = [UInt8](repeating: 0x72, count: ProtocolBufferConfig.maxRouteBytes)
        let snapshot = routeBytes.withUnsafeBufferPointer { buffer in
            BorrowedProtocolRouteSnapshot(slice: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
        }
        #expect(snapshot?.length == ProtocolBufferConfig.maxRouteBytes)
        #expect(snapshot?.owned() == routeBytes)

        let oversized = routeBytes + [0x73]
        let rejected = oversized.withUnsafeBufferPointer { buffer in
            BorrowedProtocolRouteSnapshot(slice: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
        }
        #expect(rejected == nil)
    }

    @Test("fixed owning sink layouts stay within the static memory gate")
    func inlineOwnedSinkLayouts() {
        let tiny = MemoryLayout<InlineOwnedProtocolActionSink<1, 512>>.size
        let staticDefault = MemoryLayout<InlineOwnedProtocolActionSink<16, 512>>.size
        let hostTest = MemoryLayout<InlineOwnedProtocolActionSink<64, 512>>.size
        print("owning-sink-layout tiny=\(tiny) static=\(staticDefault) host=\(hostTest)")
        #expect(tiny > 0)
        #expect(staticDefault <= 20 * 1024)
        #expect(hostTest > staticDefault)
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

    @Test("borrowed frames reject topics beyond the owning storage limit")
    func longProfileTopicRejected() throws {
        let topic = Array((
            "coaty/3/wire-lifecycle-duplicate-reply-wire-32734211309-2/RTN/"
                + "33333333-3333-4333-8333-333333333333/"
                + "55555555-5555-4555-8555-555555555555"
        ).utf8)
        #expect(topic.count == 135)
        let payload = [UInt8]()
        #expect(throws: ProtocolError.self) {
            try topic.withUnsafeBufferPointer { topicBuffer in
                try payload.withUnsafeBufferPointer { payloadBuffer in
                    let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
                    let bytes = ByteSlice(
                        bytes: payloadBuffer.baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!,
                        length: 0
                    )
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
