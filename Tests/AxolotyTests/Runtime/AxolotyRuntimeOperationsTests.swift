// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

extension AxolotyRuntimeTests {
    @Test("runtime uses the shared processor for an accepted local publication")
    func acceptsLocalOperation() async throws {
        let definition = try makeDefinition()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        let receipt = await runtime.publish(.channel(
            identifier: "accepted-local-publication",
            payload: Array(#"{"privateData":{"accepted":true}}"#.utf8)
        ))
        #expect(receipt == .accepted)
        try await waitUntil("local operation to reach the transport") {
            await transport.sentCount() == 1
        }
        #expect(await transport.sentCount() == 1)
        await runtime.stop()
    }

    @Test("Call operation names remain topic filters on outbound actions")
    func callOperationNameReachesTransportAction() async throws {
        let definition = try makeDefinition()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        let correlation = try #require(UUID16(parsing: "55555555-5555-4555-8555-555555555555"))
        let receipt = await runtime.request(.call(
            correlationID: correlation,
            operation: "wire-fixture-operation",
            payload: Array(#"{"parameters":{"operand":7}}"#.utf8),
            timeoutMS: 1_000
        ))
        #expect(receipt == .accepted)
        try await waitUntil("Call operation to reach the transport") {
            await transport.sentCount() == 1
        }
        let action = try #require(await transport.lastSent())
        guard case .profile(let filter, _) = action.target else {
            Issue.record("Call publication did not use the profile target")
            return
        }
        #expect(filter == Array("wire-fixture-operation".utf8))
        await runtime.stop()
    }

    @Test("Channel identifiers remain typed topic filters on outbound actions")
    func channelIdentifierReachesTransportAction() async throws {
        let definition = try makeDefinition()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        let receipt = await runtime.publish(.channel(
            identifier: "wire-fixture-channel",
            payload: Array(#"{"privateData":{"sequence":7}}"#.utf8)
        ))
        #expect(receipt == .accepted)
        try await waitUntil("Channel operation to reach the transport") {
            await transport.sentCount() == 1
        }
        let action = try #require(await transport.lastSent())
        guard case .profile(let filter, let kind) = action.target else {
            Issue.record("Channel publication did not use the profile target")
            return
        }
        #expect(filter == Array("wire-fixture-channel".utf8))
        #expect(kind == .direct)
        await runtime.stop()
    }

    @Test("dispatch reservation rejects a complete multi-action publication atomically")
    func multiActionDispatchReservationIsAtomic() async throws {
        let definition = try RuntimeDefinition(
            namespace: "test",
            sourceID: .zero,
            capacities: try RuntimeCapacities(dispatch: 1)
        ).seal()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        let payload = Array(#"{"object":{"objectId":"66666666-6666-4666-8666-666666666666","coreType":"CoatyObject","objectType":"com.coaty.test.WireQueuedFixture","name":"first"}}"#.utf8)
        #expect(await runtime.publish(.advertise(payload)) == .rejected(.capacityExceeded))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.sentCount() == 0)
        await runtime.stop()
    }

    @Test("default request deadlines use the monotonic runtime clock")
    func defaultRequestUsesMonotonicClock() async throws {
        let definition = try makeDefinition()
        let runtime = AxolotyRuntime(definition: definition, transport: TestTransport())
        try await runtime.start()
        let correlation = try #require(UUID16(parsing: "57575757-5757-4575-8575-575757575757"))
        #expect(await runtime.request(.discover(
            correlationID: correlation,
            payload: Array("{}".utf8),
            timeoutMS: 1
        )) == .accepted)
        #expect(await runtime.expire(nowMS: 1) == false)
        await runtime.stop()
    }

    @Test("unlimited Discover correlations remain active until canceled")
    func unlimitedDiscoverCanBeCanceled() async throws {
        let definition = try makeDefinition()
        let runtime = AxolotyRuntime(definition: definition, transport: TestTransport())
        try await runtime.start()
        let correlation = try #require(UUID16(parsing: "58585858-5858-4585-8585-585858585858"))
        #expect(await runtime.request(.discover(
            correlationID: correlation,
            payload: Array("{}".utf8),
            timeoutMS: nil
        )) == .accepted)
        #expect(await runtime.cancel(correlationID: correlation))
        await runtime.stop()
    }

    @Test("invalid Call operation names are rejected before publication")
    func rejectsInvalidCallOperationNames() async throws {
        let definition = try makeDefinition()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        let correlation = try #require(UUID16(parsing: "56565656-5656-4565-8565-565656565656"))
        let invalidNames = [
            "",
            "invalid/operation",
            "invalid\0operation",
            String(repeating: "x", count: RuntimeOperationValidation.maximumUTF8Bytes + 1)
        ]
        for operation in invalidNames {
            let receipt = await runtime.request(.call(
                correlationID: correlation,
                operation: operation,
                payload: Array(#"{"parameters":{"operand":7}}"#.utf8),
                timeoutMS: 1_000
            ))
            #expect(receipt == .rejected(.invalidOperationName))
        }
        #expect(await transport.sentCount() == 0)
        await runtime.stop()
    }
}

