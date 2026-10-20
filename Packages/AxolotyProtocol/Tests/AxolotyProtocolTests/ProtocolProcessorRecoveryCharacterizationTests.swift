// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyProtocol
import AxolotyWire

extension ProtocolProcessorTests {
    @Test("transport reset makes remote presence uncertain until fresh evidence")
    func resetMakesRemotePresenceUncertain() throws {
        let sourceText = "00000000-0000-4000-8000-000000000001"
        let objectID = "22222222-2222-4222-8222-222222222222"
        let payload = "{\"object\":{\"objectId\":\"\(objectID)\"}}"
        var processor = ProtocolProcessor<2>()

        let first = try withBorrowedFrame(
            topic: "coaty/3/test/ADV/\(sourceText)",
            payload: payload
        ) { frame in
            var sink = InlineProtocolActionSink<2>()
            return processor.processInbound(.profile(frame), nowMS: 1, sink: &sink)
        }
        #expect(first == .accepted)
        #expect(processor.state.activeObjects == 1)

        processor.resetTransport()
        #expect(processor.state.activeObjects == 0)

        let renewed = try withBorrowedFrame(
            topic: "coaty/3/test/ADV/\(sourceText)",
            payload: payload
        ) { frame in
            var sink = InlineProtocolActionSink<2>()
            return processor.processInbound(.profile(frame), nowMS: 2, sink: &sink)
        }
        #expect(renewed == .accepted)
        #expect(processor.state.activeObjects == 1)

        let duplicate = try withBorrowedFrame(
            topic: "coaty/3/test/ADV/\(sourceText)",
            payload: payload
        ) { frame in
            var sink = InlineProtocolActionSink<2>()
            return processor.processInbound(.profile(frame), nowMS: 3, sink: &sink)
        }
        #expect(duplicate == .rejected(.duplicate))
        #expect(processor.state.activeObjects == 1)
    }

    @Test("transport reset retains the local incarnation for exactly one replay")
    func resetRetainsLocalIncarnationForOneReplay() throws {
        let objectID = "11111111-1111-4111-8111-111111111111"
        let payload: StaticString = "{\"object\":{\"objectId\":\"11111111-1111-4111-8111-111111111111\"}}"
        let advertise = try ProtocolLocalOperation(
            capability: .advertise,
            sourceID: .zero,
            payload: protocolSlice(payload)
        )
        var processor = ProtocolProcessor<2>()
        var sink = InlineProtocolActionSink<2>()
        #expect(processor.processOutbound(advertise, sink: &sink) == .accepted)
        sink.removeAll()

        var before = ProtocolFixedStateSnapshot<2>()
        processor.copyState(into: &before)
        #expect(before.activeObjectCount == 1)
        #expect(UUID16(parsing: objectID) == before.activeObjectIDs[0])

        processor.resetTransport()
        var afterReset = ProtocolFixedStateSnapshot<2>()
        processor.copyState(into: &afterReset)
        #expect(afterReset.activeObjectCount == 1)
        #expect(afterReset.activeObjectIDs[0] == before.activeObjectIDs[0])

        #expect(processor.processOutbound(advertise, sink: &sink) == .accepted)
        sink.removeAll()
        #expect(processor.processOutbound(advertise, sink: &sink) == .rejected(.duplicate))
        #expect(processor.state.activeObjects == 1)
    }

    @Test("discovery refresh stays bounded and frees capacity only at expiry")
    func boundedDiscoveryRefresh() throws {
        let first = try #require(UUID16(parsing: "10000000-0000-4000-8000-000000000001"))
        let second = try #require(UUID16(parsing: "10000000-0000-4000-8000-000000000002"))
        let third = try #require(UUID16(parsing: "10000000-0000-4000-8000-000000000003"))
        var processor = ProtocolProcessor<2>(maximumPendingCorrelations: 1)

        #expect(startDiscover(&processor, correlation: first, nowMS: 100, timeoutMS: 60))
        #expect(!startDiscover(&processor, correlation: second, nowMS: 100, timeoutMS: 60))
        #expect(processor.state.pendingCorrelations == 1)

        let earlyExpiry = processor.expire(nowMS: 159)
        let expired = processor.expire(nowMS: 160)
        #expect(earlyExpiry == false)
        #expect(expired)
        #expect(processor.state.pendingCorrelations == 0)

        let stale = try withResponseFrame(correlation: first.topicString) { frame in
            var sink = InlineProtocolActionSink<2>()
            return processor.processInbound(.profile(frame), nowMS: 160, sink: &sink)
        }
        #expect(stale == .rejected(.deadlineExpired))
        #expect(startDiscover(&processor, correlation: second, nowMS: 160, timeoutMS: 60))
        #expect(!startDiscover(&processor, correlation: third, nowMS: 160, timeoutMS: 60))
        #expect(processor.state.pendingCorrelations == 1)
    }

    @Test("explicit correlation saturation rejects the second request without mutation")
    func explicitCorrelationSaturation() throws {
        let first = try #require(UUID16(parsing: "20000000-0000-4000-8000-000000000001"))
        let second = try #require(UUID16(parsing: "20000000-0000-4000-8000-000000000002"))
        var processor = ProtocolProcessor<2>(maximumPendingCorrelations: 1)

        #expect(startDiscover(&processor, correlation: first, nowMS: 100, timeoutMS: 1_000))
        let rejection = startDiscoverReceipt(&processor, correlation: second, nowMS: 100, timeoutMS: 1_000)
        #expect(rejection == .rejected(.capacityExceeded))
        #expect(processor.state.pendingCorrelations == 1)

        let cancelled = processor.cancel(correlationID: first)
        #expect(cancelled)
        #expect(processor.state.pendingCorrelations == 0)
        #expect(startDiscover(&processor, correlation: second, nowMS: 101, timeoutMS: 1_000))
    }

    @Test("multi-response families emit each partial result before completion")
    func multiResponsePartialResults() throws {
        let correlation = try #require(UUID16(parsing: "30000000-0000-4000-8000-000000000001"))
        var processor = ProtocolProcessor<2>()
        #expect(startDiscover(&processor, correlation: correlation, nowMS: 10, timeoutMS: 1_000))

        for nowMS: UInt32 in [20, 30] {
            let outcome = try withResponseFrame(correlation: correlation.topicString, event: "RSV") { frame in
                var sink = InlineProtocolActionSink<2>()
                let outcome = processor.processInbound(.profile(frame), nowMS: nowMS, sink: &sink)
                #expect(sink.count == 1)
                return outcome
            }
            #expect(outcome == .accepted)
            #expect(processor.state.pendingCorrelations == 1)
        }

        let cancelled = processor.cancel(correlationID: correlation)
        #expect(cancelled)
        #expect(processor.state.pendingCorrelations == 0)
    }

    @Test("a transport that excludes Discover rejects local and remote use")
    func transportCapabilityRejection() throws {
        let limited = ProtocolCapabilities(
            .advertise, .deadvertise, .channel, .associate, .ioValue, .resolve
        )
        var processor = ProtocolProcessor<2>(capabilities: limited)
        let correlation = try #require(UUID16(parsing: "40000000-0000-4000-8000-000000000001"))

        let outbound = startDiscoverReceipt(&processor, correlation: correlation, nowMS: 10, timeoutMS: 100)
        #expect(outbound == .rejected(.unsupportedCapability))
        #expect(processor.state.pendingCorrelations == 0)
        #expect(processor.state.generation == 0)

        let inbound = try withBorrowedFrame(
            topic: "coaty/3/test/DSC/00000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000002",
            payload: "{}"
        ) { frame in
            var sink = InlineProtocolActionSink<2>()
            return processor.processInbound(.profile(frame), nowMS: 11, sink: &sink)
        }
        #expect(inbound == .rejected(.unsupportedCapability))
        #expect(processor.state.pendingCorrelations == 0)
        #expect(processor.state.generation == 0)
    }
}

private func startDiscover(
    _ processor: inout ProtocolProcessor<2>,
    correlation: UUID16,
    nowMS: UInt32,
    timeoutMS: UInt32
) -> Bool {
    startDiscoverReceipt(
        &processor,
        correlation: correlation,
        nowMS: nowMS,
        timeoutMS: timeoutMS
    ) == .accepted
}

private func startDiscoverReceipt(
    _ processor: inout ProtocolProcessor<2>,
    correlation: UUID16,
    nowMS: UInt32,
    timeoutMS: UInt32
) -> ProtocolProcessOutcome {
    do {
        let operation = try ProtocolLocalOperation(
            capability: .discover,
            sourceID: correlation,
            correlationID: correlation,
            payload: protocolSlice("{}"),
            requestTimeoutMS: timeoutMS
        )
        var sink = InlineProtocolActionSink<2>()
        return processor.processOutbound(operation, nowMS: nowMS, sink: &sink)
    } catch {
        return .rejected(.malformedPayload)
    }
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
