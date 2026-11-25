// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

extension AxolotyRuntimeTests {
    @Test("a peer deadvertise releases its host association and notifies observers once")
    func hostDeadvertiseReleasesAssociation() async throws {
        let localActorID = "00000000-0000-4000-8000-0000000007a2"
        let peerSourceID = "00000000-0000-4000-8000-0000000007a1"
        let peer = try #require(UUID16(parsing: peerSourceID))
        let actorJSON: StaticString = """
        {"objectId":"00000000-0000-4000-8000-0000000007a2","objectType":"coaty.IoActor","name":"host-actor","coreType":"IoActor","valueType":"com.example.Bool"}
        """
        let actorObject = try Object<IoActorMetadata>(decoding: ByteSlice(
            bytes: actorJSON.utf8Start,
            length: actorJSON.utf8CodeUnitCount
        ))
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: "release")
        let actor = try builder.ioActor(metadata: actorObject, as: Bool.self) { _, _ in }
        let events = try builder.events(matching: .family(.deadvertise), buffering: .dropOldest(capacity: 4))
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: TestTransport())
        try await runtime.start()
        let associations = try await runtime.io.associations(of: actor, buffering: .dropOldest(capacity: 4))
        var associationIterator = associations.makeAsyncIterator()
        #expect(try await nextValue(&associationIterator).hasAssociations == false)

        let advertise = Array("""
        {"object":{"objectId":"\(peerSourceID)","coreType":"IoSource","objectType":"coaty.IoSource","name":"peer-source"}}
        """.utf8)
        #expect(await runtime.receive(.profile(
            route: "coaty/3/release/ADV/\(peerSourceID)",
            payload: advertise,
            nowMS: 1
        )) == .accepted)

        let associate = Array("""
        {"ioSourceId":"\(peerSourceID)","ioActorId":"\(localActorID)","associatingRoute":"coaty/io-release"}
        """.utf8)
        #expect(await runtime.receive(.profile(
            route: "coaty/3/release/ASC/\(peerSourceID)",
            payload: associate,
            nowMS: 2
        )) == .accepted)
        #expect(try await runtime.io.state(of: actor).hasAssociations)
        #expect(try await nextValue(&associationIterator).hasAssociations)

        let deadvertise = Array("{\"objectIds\":[\"\(peerSourceID)\"]}".utf8)
        #expect(await runtime.receive(.profile(
            route: "coaty/3/release/DAD/\(peerSourceID)",
            payload: deadvertise,
            nowMS: 3
        )) == .accepted)

        // The released slot is gone, so the local actor's IoState is false.
        let released = try await runtime.io.state(of: actor)
        #expect(released.hasAssociations == false)
        #expect(released.associationCount == 0)
        #expect(try await nextValue(&associationIterator).hasAssociations == false)

        // The Deadvertise frame reaches the event stream exactly once; the
        // synthesized release must not be dispatched as a second event.
        var eventIterator = events.makeAsyncIterator()
        let event = try await nextValue(&eventIterator)
        #expect(event.context.sourceID == peer)
        #expect(event.value == deadvertise)
        do {
            _ = try await nextValue(&eventIterator, timeout: .milliseconds(200))
            Issue.record("the synthesized release was dispatched as a second Deadvertise event")
        } catch is AsyncWaitTimeoutError {
        }

        await runtime.stop()
    }
}
