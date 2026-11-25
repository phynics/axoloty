// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyProtocol
import AxolotyWire

/// A lost peer's Associate entries hold their fixed slots until a local
/// transport reset. A graceful stop, or a broker last will on an unclean
/// disconnect, delivers a Deadvertise for the lost peer's advertised objects.
/// Removing those objects must release the association endpoints they owned so
/// the slots become reusable and observers learn the actor's IoState is false.
/// Unclean loss without any Deadvertise remains #1060's soft-state presence
/// work; these tests pin the absence signal the protocol already has.
extension ProtocolProcessorTests {
    private static let releasedSource = "00000000-0000-4000-8000-0000000000a1"
    private static let releasedActor = "00000000-0000-4000-8000-0000000000a2"
    private static let liveSource = "00000000-0000-4000-8000-0000000000b1"
    private static let liveActor = "00000000-0000-4000-8000-0000000000b2"
    private static let freshSource = "00000000-0000-4000-8000-0000000000c1"
    private static let freshActor = "00000000-0000-4000-8000-0000000000c2"

    private static func advertises(_ source: String, coreType: String = "IoSource") -> String {
        """
        {"object":{"objectId":"\(source)","coreType":"\(coreType)","objectType":"coaty.\(coreType)","name":"endpoint"}}
        """
    }

    private static func associate(_ source: String, _ actor: String) -> String {
        """
        {"ioSourceId":"\(source)","ioActorId":"\(actor)","associatingRoute":"coaty/3/io/route"}
        """
    }

    private static func advertise(
        _ source: String,
        coreType: String = "IoSource",
        into processor: inout ProtocolProcessor<2>
    ) throws {
        try withBorrowedFrame(
            topic: "coaty/3/test/ADV/\(source)",
            payload: advertises(source, coreType: coreType)
        ) { frame in
            var sink = InlineProtocolActionSink<4>()
            #expect(processor.processInbound(.profile(frame), nowMS: 1, sink: &sink) == .accepted)
        }
    }

    private static func associate(
        _ source: String,
        _ actor: String,
        into processor: inout ProtocolProcessor<2>,
        _ body: (ProtocolProcessOutcome) -> Void = { _ in }
    ) throws {
        try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(source)",
            payload: associate(source, actor)
        ) { frame in
            var sink = InlineProtocolActionSink<4>()
            body(processor.processInbound(.profile(frame), nowMS: 2, sink: &sink))
        }
    }

    private static func deadvertise(
        _ object: String,
        from source: String,
        into processor: inout ProtocolProcessor<2>,
        _ body: (ProtocolProcessOutcome, borrowing InlineProtocolActionSink<8>) -> Void
    ) throws {
        try withBorrowedFrame(
            topic: "coaty/3/test/DAD/\(source)",
            payload: "{\"objectIds\":[\"\(object)\"]}"
        ) { frame in
            var sink = InlineProtocolActionSink<8>()
            let outcome = processor.processInbound(.profile(frame), nowMS: 3, sink: &sink)
            body(outcome, sink)
        }
    }

    @Test("a lost peer's deadvertise releases its association slots")
    func deadvertiseReleasesAssociationSlots() throws {
        var processor = ProtocolProcessor<2>()
        try Self.advertise(Self.releasedSource, into: &processor)
        try Self.advertise(Self.liveSource, into: &processor)
        try Self.associate(Self.releasedSource, Self.releasedActor, into: &processor)
        try Self.associate(Self.liveSource, Self.liveActor, into: &processor)
        #expect(processor.state.activeAssociations == 2)

        // A lost peer keeps its row until this release, so the table saturates.
        try Self.associate(Self.freshSource, Self.freshActor, into: &processor) { outcome in
            #expect(outcome == .rejected(.capacityExceeded))
        }
        #expect(processor.state.activeAssociations == 2)

        try Self.deadvertise(Self.releasedSource, from: Self.releasedSource, into: &processor) { outcome, _ in
            #expect(outcome == .accepted)
        }
        #expect(processor.state.activeAssociations == 1)
        #expect(processor.ioAssociationState(forSource: UUID16(parsing: Self.releasedSource)!).hasAssociations == false)
        #expect(processor.ioAssociationState(forSource: UUID16(parsing: Self.liveSource)!).hasAssociations == true)
        #expect(processor.ioAssociationState(forActor: UUID16(parsing: Self.releasedActor)!).hasAssociations == false)

        try Self.associate(Self.freshSource, Self.freshActor, into: &processor) { outcome in
            #expect(outcome == .accepted)
        }
        #expect(processor.state.activeAssociations == 2)
    }

    @Test("a deadvertise reports the released association")
    func deadvertiseReleaseReportsObservers() throws {
        var processor = ProtocolProcessor<2>()
        try Self.advertise(Self.releasedSource, into: &processor)
        try Self.associate(Self.releasedSource, Self.releasedActor, into: &processor)

        try Self.deadvertise(Self.releasedSource, from: Self.releasedSource, into: &processor) { outcome, sink in
            #expect(outcome == .accepted)
            #expect(sink.count == 2)
            guard case .deliver(let delivered) = sink[0] else {
                Issue.record("deadvertise was not delivered")
                return
            }
            #expect(delivered.routingKey.capability == .deadvertise)
            guard case .associationChanged(let transition) = sink[1] else {
                Issue.record("released association was not reported")
                return
            }
            #expect(transition.change == .removed)
            #expect(transition.sourceID == UUID16(parsing: Self.releasedSource))
            #expect(transition.actorID == UUID16(parsing: Self.releasedActor))
            #expect(transition.delivery.routingKey.capability == .deadvertise)
            #expect(transition.routeClassification == .coaty)
        }
    }

    @Test("a deadvertise releases associations owned by either endpoint")
    func deadvertiseReleasesActorEndpointAssociations() throws {
        var processor = ProtocolProcessor<2>()
        try Self.advertise(Self.releasedActor, coreType: "IoActor", into: &processor)
        try Self.associate(Self.releasedSource, Self.releasedActor, into: &processor)
        #expect(processor.state.activeAssociations == 1)

        try Self.deadvertise(Self.releasedActor, from: Self.releasedActor, into: &processor) { outcome, _ in
            #expect(outcome == .accepted)
        }
        #expect(processor.state.activeAssociations == 0)
        #expect(processor.ioAssociationState(forSource: UUID16(parsing: Self.releasedSource)!).hasAssociations == false)
    }

    @Test("another peer cannot release a live peer's associations")
    func unrelatedDeadvertiseKeepsAssociations() throws {
        var processor = ProtocolProcessor<2>()
        try Self.advertise(Self.liveSource, into: &processor)
        try Self.associate(Self.liveSource, Self.liveActor, into: &processor)

        // The sender does not own the named object, so neither the object nor
        // its association is removed.
        try Self.deadvertise(Self.liveSource, from: Self.freshSource, into: &processor) { outcome, _ in
            #expect(outcome == .accepted)
        }
        #expect(processor.state.activeObjects == 1)
        #expect(processor.state.activeAssociations == 1)
        #expect(processor.ioAssociationState(forSource: UUID16(parsing: Self.liveSource)!).hasAssociations == true)
    }

    @Test("an external association is deactivated before the release is reported")
    func deadvertiseReleaseOrderForExternalRoute() throws {
        let externalRoute = "external/io-a"
        var processor = ProtocolProcessor<2>()
        try Self.advertise(Self.releasedSource, into: &processor)

        try withBorrowedFrame(
            topic: "coaty/3/test/ASC/\(Self.releasedSource)",
            payload: """
            {"ioSourceId":"\(Self.releasedSource)","ioActorId":"\(Self.releasedActor)","associatingRoute":"\(externalRoute)"}
            """
        ) { frame in
            var sink = InlineProtocolActionSink<4>()
            #expect(processor.processInbound(
                .profile(frame),
                nowMS: 2,
                classifier: MultiExternalRouteClassifier(),
                sink: &sink
            ) == .accepted)
        }

        try Self.deadvertise(Self.releasedSource, from: Self.releasedSource, into: &processor) { outcome, sink in
            #expect(outcome == .accepted)
            #expect(sink.count == 3)
            guard case .externalRouteDeactivated(let deactivated) = sink[1] else {
                Issue.record("external route was not deactivated before release")
                return
            }
            #expect(deactivated.sourceID == UUID16(parsing: Self.releasedSource))
            #expect(deactivated.route.owned() == Array(externalRoute.utf8))
            guard case .associationChanged(let transition) = sink[2] else {
                Issue.record("released external association was not reported")
                return
            }
            #expect(transition.change == .removed)
            #expect(transition.route?.owned() == Array(externalRoute.utf8))
            #expect(transition.routeClassification == .external)
        }
    }

    @Test("a sink that cannot hold the release leaves state unchanged")
    func deadvertiseReleaseRejectsWithoutMutation() throws {
        var processor = ProtocolProcessor<2>()
        try Self.advertise(Self.releasedSource, into: &processor)
        try Self.associate(Self.releasedSource, Self.releasedActor, into: &processor)

        // The Deadvertise delivery plus the release report need two slots.
        try withBorrowedFrame(
            topic: "coaty/3/test/DAD/\(Self.releasedSource)",
            payload: "{\"objectIds\":[\"\(Self.releasedSource)\"]}"
        ) { frame in
            var sink = InlineProtocolActionSink<1>()
            let outcome = processor.processInbound(.profile(frame), nowMS: 3, sink: &sink)
            #expect(outcome == .rejected(.capacityExceeded))
            #expect(sink.count == 0)
        }
        #expect(processor.state.activeObjects == 1)
        #expect(processor.state.activeAssociations == 1)
    }
}
