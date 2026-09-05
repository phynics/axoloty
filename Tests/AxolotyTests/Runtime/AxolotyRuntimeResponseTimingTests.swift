// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

extension AxolotyRuntimeTests {
    @Test("local responder completion stamps the response event with real monotonic time")
    func responderCompletionUsesMonotonicTime() async throws {
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: "test", capacities: try RuntimeCapacities())
        let correlation = try #require(UUID16(parsing: "99999999-9999-4999-8999-999999999999"))
        let stream = try builder.events(
            matching: .correlatedResponse(capability: .returnEvent, correlationID: correlation),
            buffering: .dropOldest(capacity: 2)
        )
        _ = try builder.respond(to: .call(operation: "wire-fixture-operation")) { _ in
            .response(Array(#"{"result":{"answer":42}}"#.utf8))
        }
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
        try await runtime.start()

        let topic = "coaty/3/test/CLL:wire-fixture-operation/"
            + "22222222-2222-4222-8222-222222222222/"
            + "99999999-9999-4999-8999-999999999999"
        let receipt = await runtime.receive(.profile(
            route: topic,
            payload: Array(#"{"parameters":{"operand":7}}"#.utf8),
            nowMS: 0
        ))
        try #require(receipt == .accepted)

        var iterator = stream.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.context.correlationID == correlation)
        // Before this fix, `complete(invocation:result:)` published the
        // response with a hardcoded `nowMS: 0`, so a locally registered
        // event stream observing this runtime's own outgoing response
        // always saw a zero receipt time instead of the real monotonic
        // clock used by every other publish path.
        #expect(event.context.receiptTimeMS > 0)

        await runtime.stop()
    }
}
