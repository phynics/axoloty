// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

extension AxolotyRuntimeTests {
    @Test("reconnect does not replay an accepted request command")
    func reconnectDoesNotReplayRequestCommands() async throws {
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: transport)
        try await runtime.start()

        let correlation = try #require(UUID16(parsing: "51000000-0000-4000-8000-000000000001"))
        await transport.failNextPublication()
        #expect(await runtime.request(.call(
            correlationID: correlation,
            operation: "wire-fixture-operation",
            payload: Array(#"{"parameters":{}}"#.utf8),
            timeoutMS: 1_000
        ), nowMS: 1) == .accepted)
        try await waitUntil("runtime to enter reconnecting after the failed request send") {
            await runtime.state() == .reconnecting
        }
        #expect(await transport.deliveredMessages().isEmpty)

        await runtime.reconnect()
        try await waitUntil("runtime to finish reconnect") {
            await runtime.state() == .running
        }
        // Give a spurious replay a chance to arrive before asserting it never does.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.deliveredMessages().isEmpty)
        #expect(await runtime.conformanceObservation().state.pendingCorrelationIDs.isEmpty)

        let late = await runtime.receive(.profile(
            route: responseRoute("RSV", correlation: "51000000-0000-4000-8000-000000000001"),
            payload: Array(#"{"object":{}}"#.utf8),
            nowMS: 2
        ))
        #expect(late == .rejected(.protocol(.correlationMismatch)))

        await runtime.stop()
    }

    @Test("explicit reconnect restores profile interest once per session")
    func explicitReconnectRestoresSubscriptions() async throws {
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: transport)
        try await runtime.start()

        let initial = await transport.profileSubscriptions()
        #expect(initial.count == 2)
        await runtime.reconnect()
        try await waitUntil("runtime to finish reconnect") {
            await runtime.state() == .running
        }

        let restored = await transport.profileSubscriptions()
        #expect(restored.count == 4)
        #expect(Set(restored) == Set(initial))
        #expect(await transport.lifecycle.filter { $0 == "activate" }.count == 2)
        #expect(await transport.lifecycle.filter { $0 == "deactivate" }.count == 1)

        await runtime.stop()
        #expect(await transport.profileUnsubscriptions().count == 4)
    }

    @Test("soft transport recovery keeps the existing subscription session")
    func softRecoveryKeepsSubscriptions() async throws {
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: transport)
        try await runtime.start()
        let initial = await transport.profileSubscriptions()

        await transport.fail(TestTransportFailure())
        try await waitUntil("runtime to enter reconnecting") {
            await runtime.state() == .reconnecting
        }
        await transport.recover()
        try await waitUntil("runtime to finish soft recovery") {
            await runtime.state() == .running
        }

        #expect(await transport.profileSubscriptions() == initial)
        #expect(await transport.lifecycle.filter { $0 == "activate" }.count == 1)
        #expect(await transport.lifecycle.filter { $0 == "deactivate" }.isEmpty)

        await runtime.stop()
    }

    @Test("bounded discovery refresh rejects overlap and frees capacity at expiry")
    func boundedDiscoveryRefresh() async throws {
        let definition = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "test",
            capacities: try RuntimeCapacities(protocolMaximumPendingCorrelations: 1)
        ).finish()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        let first = try #require(UUID16(parsing: "52000000-0000-4000-8000-000000000001"))
        let second = try #require(UUID16(parsing: "52000000-0000-4000-8000-000000000002"))
        #expect(await runtime.request(.discover(
            correlationID: first,
            payload: Array("{}".utf8),
            timeoutMS: 60
        ), nowMS: 100) == .accepted)
        #expect(await runtime.request(.discover(
            correlationID: second,
            payload: Array("{}".utf8),
            timeoutMS: 60
        ), nowMS: 100) == .rejected(.capacityExceeded))
        #expect(await runtime.conformanceObservation().state.pendingCorrelationIDs == [first])

        #expect(await runtime.expire(nowMS: 159) == false)
        #expect(await runtime.expire(nowMS: 160))
        #expect(await runtime.request(.discover(
            correlationID: second,
            payload: Array("{}".utf8),
            timeoutMS: 60
        ), nowMS: 160) == .accepted)
        #expect(await runtime.conformanceObservation().state.pendingCorrelationIDs == [second])

        await runtime.stop()
    }

    @Test("deadline and cancellation produce distinct terminal outcomes")
    func deadlineAndCancellationOutcomes() async throws {
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: transport)
        try await runtime.start()

        let discover = try #require(UUID16(parsing: "53000000-0000-4000-8000-000000000001"))
        let query = try #require(UUID16(parsing: "53000000-0000-4000-8000-000000000002"))
        let refreshed = try #require(UUID16(parsing: "53000000-0000-4000-8000-000000000003"))
        #expect(await runtime.request(.discover(
            correlationID: discover,
            payload: Array("{}".utf8),
            timeoutMS: 50
        ), nowMS: 100) == .accepted)
        #expect(await runtime.request(.query(
            correlationID: query,
            payload: Array("{}".utf8),
            timeoutMS: 100
        ), nowMS: 100) == .accepted)

        #expect(await runtime.receive(.profile(
            route: responseRoute("RSV", correlation: discover.topicString),
            payload: Array(#"{"object":{}}"#.utf8),
            nowMS: 149
        )) == .accepted)
        #expect(await runtime.expire(nowMS: 149) == false)
        #expect(await runtime.expire(nowMS: 150))
        #expect(await runtime.diagnosticsSnapshot().expiredRequests == 1)

        let late = await runtime.receive(.profile(
            route: responseRoute("RSV", correlation: discover.topicString),
            payload: Array(#"{"object":{}}"#.utf8),
            nowMS: 151
        ))
        #expect(late == .rejected(.protocol(.deadlineExpired)))

        #expect(await runtime.cancel(correlationID: query))
        #expect(await runtime.cancel(correlationID: query) == false)
        let cancelled = await runtime.receive(.profile(
            route: responseRoute("RTV", correlation: query.topicString),
            payload: Array(#"{"objects":[]}"#.utf8),
            nowMS: 152
        ))
        #expect(cancelled == .rejected(.protocol(.duplicate)))

        #expect(await runtime.request(.discover(
            correlationID: refreshed,
            payload: Array("{}".utf8),
            timeoutMS: 1_000
        ), nowMS: 153) == .accepted)
        #expect(await runtime.conformanceObservation().state.pendingCorrelationIDs == [refreshed])

        await runtime.stop()
    }

    @Test("a multi-response request delivers every partial result before completion")
    func partialMultiResponseResults() async throws {
        let discover = try #require(UUID16(parsing: "54000000-0000-4000-8000-000000000001"))
        let query = try #require(UUID16(parsing: "54000000-0000-4000-8000-000000000002"))
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: "test")
        let resolves = try builder.events(
            matching: .correlatedResponse(capability: .resolve, correlationID: discover),
            buffering: .dropOldest(capacity: 4)
        )
        let retrieveAndComplete = try builder.events(
            matching: .correlatedResponse(capability: .complete, correlationID: query),
            buffering: .dropOldest(capacity: 4)
        )
        let retrieves = try builder.events(
            matching: .correlatedResponse(capability: .retrieve, correlationID: query),
            buffering: .dropOldest(capacity: 4)
        )
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: TestTransport())
        try await runtime.start()

        #expect(await runtime.request(.discover(
            correlationID: discover,
            payload: Array("{}".utf8),
            timeoutMS: 1_000
        ), nowMS: 10) == .accepted)
        #expect(await runtime.request(.query(
            correlationID: query,
            payload: Array("{}".utf8),
            timeoutMS: 1_000
        ), nowMS: 10) == .accepted)

        let resolveBox = RuntimeTestIteratorBox(resolves.makeAsyncIterator())
        let retrieveBox = RuntimeTestIteratorBox(retrieves.makeAsyncIterator())
        let completeBox = RuntimeTestIteratorBox(retrieveAndComplete.makeAsyncIterator())

        for nowMS: UInt32 in [20, 30] {
            #expect(await runtime.receive(.profile(
                route: responseRoute("RSV", correlation: discover.topicString),
                payload: Array(#"{"object":{}}"#.utf8),
                nowMS: nowMS
            )) == .accepted)
            let event = try await withTimeout("partial resolve event", timeout: .seconds(2)) {
                await resolveBox.next()
            }
            #expect(event?.context.correlationID == discover)
            #expect(await runtime.conformanceObservation().state.pendingCorrelationIDs == [discover, query])
        }

        #expect(await runtime.receive(.profile(
            route: responseRoute("RTV", correlation: query.topicString),
            payload: Array(#"{"objects":[]}"#.utf8),
            nowMS: 40
        )) == .accepted)
        let retrieveEvent = try await withTimeout("retrieve event", timeout: .seconds(2)) {
            await retrieveBox.next()
        }
        #expect(retrieveEvent?.context.correlationID == query)

        #expect(await runtime.receive(.profile(
            route: responseRoute("CPL", correlation: query.topicString),
            payload: Array("{}".utf8),
            nowMS: 50
        )) == .accepted)
        let completeEvent = try await withTimeout("complete event", timeout: .seconds(2)) {
            await completeBox.next()
        }
        #expect(completeEvent?.context.correlationID == query)
        #expect(await runtime.conformanceObservation().state.pendingCorrelationIDs == [discover])

        #expect(await runtime.cancel(correlationID: discover))
        await runtime.stop()
    }

    @Test("capacity rejects a second outstanding correlation explicitly")
    func explicitCorrelationSaturation() async throws {
        let definition = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "test",
            capacities: try RuntimeCapacities(protocolMaximumPendingCorrelations: 1)
        ).finish()
        let runtime = AxolotyRuntime(definition: definition, transport: TestTransport())
        try await runtime.start()

        let first = try #require(UUID16(parsing: "55000000-0000-4000-8000-000000000001"))
        let second = try #require(UUID16(parsing: "55000000-0000-4000-8000-000000000002"))
        #expect(await runtime.request(.discover(
            correlationID: first,
            payload: Array("{}".utf8),
            timeoutMS: 1_000
        ), nowMS: 10) == .accepted)
        #expect(await runtime.request(.discover(
            correlationID: second,
            payload: Array("{}".utf8),
            timeoutMS: 1_000
        ), nowMS: 10) == .rejected(.capacityExceeded))
        #expect(await runtime.conformanceObservation().state.pendingCorrelationIDs == [first])

        #expect(await runtime.cancel(correlationID: first))
        #expect(await runtime.request(.discover(
            correlationID: second,
            payload: Array("{}".utf8),
            timeoutMS: 1_000
        ), nowMS: 11) == .accepted)
        #expect(await runtime.conformanceObservation().state.pendingCorrelationIDs == [second])

        await runtime.stop()
    }

    @Test("runtime profile rejects an excluded transport capability without mutation")
    func transportCapabilityRejection() async throws {
        let limits = try RuntimeCapacities(
            protocolCapabilities: ProtocolCapabilities(
                .advertise, .deadvertise, .channel, .associate, .ioValue, .resolve
            )
        )
        let definition = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "test",
            capacities: limits
        ).finish()
        let runtime = AxolotyRuntime(definition: definition, transport: TestTransport())
        try await runtime.start()

        let correlation = try #require(UUID16(parsing: "56000000-0000-4000-8000-000000000001"))
        #expect(await runtime.request(.discover(
            correlationID: correlation,
            payload: Array("{}".utf8),
            timeoutMS: 100
        ), nowMS: 10) == .rejected(.protocol(.unsupportedCapability)))
        #expect(await runtime.conformanceObservation().state.pendingCorrelationIDs.isEmpty)

        let inbound = await runtime.receive(.profile(
            route: "coaty/3/test/DSC/00000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000002",
            payload: Array("{}".utf8),
            nowMS: 11
        ))
        #expect(inbound == .rejected(.protocol(.unsupportedCapability)))
        #expect(await runtime.conformanceObservation().state.pendingCorrelationIDs.isEmpty)

        await runtime.stop()
    }
}

private func responseRoute(_ event: String, correlation: String) -> String {
    "coaty/3/test/\(event)/00000000-0000-4000-8000-000000000001/\(correlation)"
}

private extension UUID16 {
    var topicString: String {
        let bytes = [
            self.bytes.0, self.bytes.1, self.bytes.2, self.bytes.3,
            self.bytes.4, self.bytes.5, self.bytes.6, self.bytes.7,
            self.bytes.8, self.bytes.9, self.bytes.10, self.bytes.11,
            self.bytes.12, self.bytes.13, self.bytes.14, self.bytes.15,
        ]
        let digits = Array("0123456789abcdef".utf8)
        let hex = bytes.map { byte in
            String(UnicodeScalar(digits[Int(byte >> 4)]))
                + String(UnicodeScalar(digits[Int(byte & 0x0f)]))
        }
        return [
            hex[0...3].joined(),
            hex[4...5].joined(),
            hex[6...7].joined(),
            hex[8...9].joined(),
            hex[10...15].joined(),
        ].joined(separator: "-")
    }
}
