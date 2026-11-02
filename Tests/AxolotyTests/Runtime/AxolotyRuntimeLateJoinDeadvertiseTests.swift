// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

extension AxolotyRuntimeTests {
    @Test("a late-joining runtime delivers a peer's identity deadvertisement (broker last will)")
    func lateJoinerReceivesIdentityDeadvertisement() async throws {
        let peerText = "00000000-0000-4000-8000-0000000009a1"
        let peer = try #require(UUID16(parsing: peerText))
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: "late-join")
        let stream = try builder.events(
            matching: .family(.deadvertise),
            buffering: .dropOldest(capacity: 4)
        )
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: TestTransport())
        try await runtime.start()

        // This runtime never saw the peer advertise, so its table is empty.
        let route = "coaty/3/late-join/DAD/\(peerText)"
        let payload = Array(#"{"objectIds":["\#(peerText)"]}"#.utf8)
        #expect(await runtime.receive(.profile(route: route, payload: payload, nowMS: 1)) == .accepted)

        var iterator = stream.makeAsyncIterator()
        let event = try await nextValue(&iterator)
        #expect(event.context.sourceID == peer)
        #expect(event.context.provenance == .transport)
        #expect(event.value == payload)

        // A repeated last will is delivered again; nothing accumulates.
        #expect(await runtime.receive(.profile(route: route, payload: payload, nowMS: 2)) == .accepted)
        #expect(try await nextValue(&iterator).value == payload)
        await runtime.stop()
    }

    @Test("a deadvertisement naming only other unknown identities is delivered as CoatyJS does")
    func lateJoinerReceivesForeignOnlyDeadvertisement() async throws {
        let peerText = "00000000-0000-4000-8000-0000000009a2"
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: "late-join")
        let stream = try builder.events(matching: .family(.deadvertise), buffering: .dropOldest(capacity: 4))
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: TestTransport())
        try await runtime.start()

        let route = "coaty/3/late-join/DAD/\(peerText)"
        let payload = Array(#"{"objectIds":["00000000-0000-4000-8000-0000000009ff"]}"#.utf8)
        #expect(await runtime.receive(.profile(route: route, payload: payload, nowMS: 1)) == .accepted)
        var iterator = stream.makeAsyncIterator()
        #expect(try await nextValue(&iterator).value == payload)

        // An empty array is well-formed in CoatyJS too.
        let empty = Array(#"{"objectIds":[]}"#.utf8)
        #expect(await runtime.receive(.profile(route: route, payload: empty, nowMS: 2)) == .accepted)
        #expect(try await nextValue(&iterator).value == empty)

        // A malformed payload is still rejected.
        let malformed = Array(#"{"objectIds":["00000000-0000-4000-8000-0000000009ff",""]}"#.utf8)
        #expect(await runtime.receive(.profile(route: route, payload: malformed, nowMS: 3))
            == .rejected(.protocol(.malformedFrame)))
        await runtime.stop()
    }

    @Test("a local deadvertise of an identity that was never announced is still rejected")
    func localUnannouncedDeadvertiseIsRejected() async throws {
        let transport = TestTransport()
        let runtime = AxolotyRuntime(
            definition: try RuntimeBuilder(sourceID: .zero, namespace: "late-join").finish(),
            transport: transport
        )
        try await runtime.start()
        let before = await transport.sentCount()
        let receipt = await runtime.publish(
            .deadvertise(Array(#"{"objectIds":["00000000-0000-4000-8000-0000000009a3"]}"#.utf8)),
            nowMS: 1
        )
        #expect(receipt == .rejected(.protocol(.malformedFrame)))
        #expect(await transport.sentCount() == before)
        await runtime.stop()
    }
}
