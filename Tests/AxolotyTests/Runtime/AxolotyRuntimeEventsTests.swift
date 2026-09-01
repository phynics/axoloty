// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

extension AxolotyRuntimeTests {
    @Test("correlated replies accept the largest namespace allowed for generated topics")
    func correlatedReplyAcceptsLongGeneratedProfileTopic() async throws {
        let namespace = String(repeating: "n", count: 64)
        let correlation = try #require(UUID16(parsing: "55555555-5555-4555-8555-555555555555"))
        let identity = try RuntimeIdentity(
            id: try #require(UUID16(parsing: "44444444-4444-4444-8444-444444444444")),
            name: "axoloty-lifecycle-subject"
        )
        var builder = try RuntimeBuilder(identity: identity, namespace: namespace)
        let stream = try builder.events(
            matching: .correlatedResponse(capability: .returnEvent, correlationID: correlation),
            buffering: .dropOldest(capacity: 2)
        )
        let runtime = AxolotyRuntime(
            definition: try builder.finish(),
            transport: TestTransport()
        )
        try await runtime.start()

        #expect(await runtime.request(.call(
            correlationID: correlation,
            operation: "wire-fixture-operation",
            payload: Array(#"{"parameters":{"operand":7}}"#.utf8),
            timeoutMS: 10_000
        ), nowMS: 1) == .accepted)

        let topic = "coaty/3/\(namespace)/RTN/"
            + "33333333-3333-4333-8333-333333333333/"
            + "55555555-5555-4555-8555-555555555555"
        #expect(topic.utf8.count == 150)
        let payload = Array(#"{"result":{"answer":49,"variant":"original"},"executionInfo":{"responder":"coatyjs-2.4.0"}}"#.utf8)
        let receipt = await runtime.receive(.profile(topic: topic, payload: payload, nowMS: 2))
        try #require(receipt == .accepted)

        var iterator = stream.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.context.correlationID == correlation)
        #expect(event.value == payload)

        let duplicatePayload = Array(
            #"{"result":{"answer":49,"variant":"duplicate"},"executionInfo":{"responder":"coatyjs-2.4.0"}}"#.utf8
        )
        #expect(await runtime.receive(.profile(
            topic: topic,
            payload: duplicatePayload,
            nowMS: 3
        )) == .rejected(.protocol(.duplicate)))

        await runtime.stop()
    }

    @Test("wire publication variants emit one logical runtime event")
    func advertiseVariantsDoNotDuplicateRuntimeEvents() async throws {
        let identity = try RuntimeIdentity(id: .zero, name: "semantic-event-test")
        var builder = try RuntimeBuilder(
            identity: identity,
            namespace: "test",
            capacities: try RuntimeCapacities(dispatch: 2)
        )
        _ = try builder.events(
            matching: .family(.advertise),
            buffering: .fail(capacity: 1)
        )
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
        try await runtime.start()

        let payload = Array(#"{"object":{"objectId":"77777777-7777-4777-8777-777777777777","coreType":"CoatyObject","objectType":"com.coaty.test.WireFixture","name":"wire-fixture"}}"#.utf8)
        #expect(await runtime.publish(.advertise(payload)) == .accepted)
        try await waitUntil("all Advertise variants to reach the transport") {
            await transport.sentCount() == 3
        }
        #expect(await transport.sentCount() == 3)
        #expect(await runtime.state() == .running)
        await runtime.stop()
    }

    @Test("advertise selectors match the payload object type")
    func advertiseSelectorMatchesPayloadObjectType() async throws {
        let identity = try RuntimeIdentity(id: .zero, name: "selector-test")
        var builder = try RuntimeBuilder(identity: identity, namespace: "test")
        let stream = try builder.events(
            matching: .advertise(objectType: "com.coaty.test.WireFixture"),
            buffering: .dropOldest(capacity: 2)
        )
        let runtime = AxolotyRuntime(
            definition: try builder.finish(),
            transport: TestTransport()
        )
        try await runtime.start()

        let iterator = RuntimeTestIteratorBox(stream.makeAsyncIterator())
        let receipt = await runtime.receive(.profile(
            topic: "coaty/3/test/ADV:CoatyObject/22222222-2222-4222-8222-222222222222",
            payload: Array(#"{"object":{"objectId":"11111111-1111-4111-8111-111111111111","coreType":"CoatyObject","objectType":"com.coaty.test.WireFixture","name":"wire-fixture"}}"#.utf8),
            nowMS: 0
        ))
        #expect(receipt == .accepted)
        let event = try await withThrowingTaskGroup(of: RuntimeEventValue?.self) { group in
            group.addTask { await iterator.next() }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw RuntimeTestTimeout.waitingForAdvertiseEvent
            }
            defer { group.cancelAll() }
            return try #require(try await group.next() ?? nil)
        }
        #expect(event.context.sourceID == UUID16(parsing: "22222222-2222-4222-8222-222222222222"))
        #expect(String(decoding: event.value, as: UTF8.self).contains("com.coaty.test.WireFixture"))
        await runtime.stop()
    }
}
