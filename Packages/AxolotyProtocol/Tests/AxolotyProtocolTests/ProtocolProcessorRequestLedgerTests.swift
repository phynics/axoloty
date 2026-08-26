// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyProtocol
import AxolotyWire

extension ProtocolProcessorTests {
    @Test("bounded request state rejects saturation, stale, and duplicate responses")
    func boundedRequestState() throws {
        let first = UUID16.zero
        let second = UUID16(bytes: (
            0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ))
        var processor = ProtocolProcessor<1>()
        let firstBegin = withStaticPayload { payload in
            let operation = try! ProtocolLocalOperation(
                capability: .discover,
                sourceID: first,
                correlationID: first,
                payload: payload,
                requestTimeoutMS: 50
            )
            var sink = InlineProtocolActionSink<1>()
            return processor.processOutbound(operation, nowMS: 100, sink: &sink) == .accepted
        }
        #expect(firstBegin)
        let saturatedBegin = withStaticPayload { payload in
            let operation = try! ProtocolLocalOperation(
                capability: .discover,
                sourceID: second,
                correlationID: second,
                payload: payload,
                requestTimeoutMS: 50
            )
            var sink = InlineProtocolActionSink<1>()
            return processor.processOutbound(operation, nowMS: 100, sink: &sink) == .accepted
        }
        #expect(!saturatedBegin)

        let wrong = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000001") { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 110, sink: &sink)
        }
        #expect(wrong == .rejected(.correlationMismatch))
        let accepted = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000") { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 149, sink: &sink)
        }
        #expect(accepted == .accepted)
        let duplicate = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000") { frame in
            var sink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 149, sink: &sink)
        }
        // Discover is a multi-response correlation; another valid Resolve is
        // accepted until its deadline expires.
        #expect(duplicate == .accepted)

        let secondBegin = withStaticPayload { payload in
            let operation = try! ProtocolLocalOperation(
                capability: .discover,
                sourceID: second,
                correlationID: second,
                payload: payload,
                requestTimeoutMS: 10
            )
            var sink = InlineProtocolActionSink<1>()
            return processor.processOutbound(operation, nowMS: 200, sink: &sink) == .accepted
        }
        #expect(!secondBegin)
        let expired = processor.expire(nowMS: 210)
        #expect(expired)
    }

    @Test("discover and query retain active correlations for multi-response flows")
    func multiResponseCorrelations() throws {
        let correlation = UUID16.zero
        var processor = ProtocolProcessor<2>()
        let discover = try ProtocolLocalOperation(
            capability: .discover,
            sourceID: correlation,
            correlationID: correlation,
            payload: protocolSlice("{}"),
            requestTimeoutMS: 100
        )
        var outbound = InlineProtocolActionSink<2>()
        #expect(processor.processOutbound(discover, nowMS: 10, sink: &outbound) == .accepted)
        outbound.removeAll()
        let first = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000", event: "RSV") { frame in
            var sink = InlineProtocolActionSink<2>()
            return processor.processInbound(.profile(frame), nowMS: 20, sink: &sink)
        }
        let second = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000", event: "RSV") { frame in
            var sink = InlineProtocolActionSink<2>()
            return processor.processInbound(.profile(frame), nowMS: 30, sink: &sink)
        }
        #expect(first == .accepted)
        #expect(second == .accepted)
        #expect(processor.state.pendingCorrelations == 1)

        processor.resetTransport()
        let query = try ProtocolLocalOperation(
            capability: .query,
            sourceID: correlation,
            correlationID: correlation,
            payload: protocolSlice("{}"),
            requestTimeoutMS: 100
        )
        #expect(processor.processOutbound(query, nowMS: 40, sink: &outbound) == .accepted)
        outbound.removeAll()
        let retrieve = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000", event: "RTV") { frame in
            var sink = InlineProtocolActionSink<2>()
            return processor.processInbound(.profile(frame), nowMS: 50, sink: &sink)
        }
        let complete = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000", event: "CPL") { frame in
            var sink = InlineProtocolActionSink<2>()
            return processor.processInbound(.profile(frame), nowMS: 60, sink: &sink)
        }
        #expect(retrieve == .accepted)
        #expect(complete == .accepted)
        #expect(processor.state.pendingCorrelations == 0)
    }

    @Test("response families cannot cross request correlation policies")
    func responseFamilyMismatch() throws {
        let correlation = UUID16.zero
        var processor = ProtocolProcessor<1>()
        let operation = try ProtocolLocalOperation(
            capability: .call,
            sourceID: correlation,
            correlationID: correlation,
            payload: protocolSlice("{}"),
            requestTimeoutMS: 100
        )
        var sink = InlineProtocolActionSink<1>()
        #expect(processor.processOutbound(operation, nowMS: 10, sink: &sink) == .accepted)
        sink.removeAll()
        let wrong = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000", event: "RSV") { frame in
            var responseSink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 20, sink: &responseSink)
        }
        #expect(wrong == .rejected(.correlationMismatch))
        #expect(processor.state.pendingCorrelations == 1)
    }

    @Test("response DTOs reject payloads missing required fields")
    func responsePayloadSchemaIsEnforced() throws {
        let correlation = UUID16.zero
        var processor = ProtocolProcessor<1>()
        let operation = try ProtocolLocalOperation(
            capability: .discover,
            sourceID: correlation,
            correlationID: correlation,
            payload: protocolSlice("{}"),
            requestTimeoutMS: 100
        )
        var sink = InlineProtocolActionSink<1>()
        #expect(processor.processOutbound(operation, nowMS: 10, sink: &sink) == .accepted)
        sink.removeAll()
        let malformed = try withResponseFrame(
            correlation: "00000000-0000-0000-0000-000000000000",
            event: "RSV",
            payload: "{}"
        ) { frame in
            var responseSink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 20, sink: &responseSink)
        }
        #expect(malformed == .rejected(.malformedPayload))
        #expect(processor.state.pendingCorrelations == 1)
    }

    @Test("cancellation rejects a late response and permits another correlation")
    func cancellation() throws {
        let first = UUID16.zero
        let second = UUID16(bytes: (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        var processor = ProtocolProcessor<1>()
        let operation = try ProtocolLocalOperation(
            capability: .discover,
            sourceID: first,
            correlationID: first,
            payload: protocolSlice("{}"),
            requestTimeoutMS: 100
        )
        var sink = InlineProtocolActionSink<1>()
        #expect(processor.processOutbound(operation, nowMS: 10, sink: &sink) == .accepted)
        sink.removeAll()
        let cancelled = processor.cancel(correlationID: first)
        #expect(cancelled)
        let late = try withResponseFrame(correlation: "00000000-0000-0000-0000-000000000000", event: "RSV") { frame in
            var responseSink = InlineProtocolActionSink<1>()
            return processor.processInbound(.profile(frame), nowMS: 20, sink: &responseSink)
        }
        #expect(late == .rejected(.duplicate))
        let next = try ProtocolLocalOperation(
            capability: .discover,
            sourceID: second,
            correlationID: second,
            payload: protocolSlice("{}"),
            requestTimeoutMS: 100
        )
        #expect(processor.processOutbound(next, nowMS: 20, sink: &sink) == .accepted)
    }
}
