// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Testing

@Suite
struct BorrowedMessageTests {
    @Test
    func withValidatedSupportsSynchronousBorrowedRead() throws {
        let topic = Array("coaty/3/test/ASC/55555555-5555-4555-8555-555555555555".utf8)
        let payload = Array(#"{"ioSourceId":"33333333-3333-4333-8333-333333333333"}"#.utf8)

        let sourceId = try topic.withUnsafeBufferPointer { topicBuffer in
            try payload.withUnsafeBufferPointer { payloadBuffer in
                try BorrowedMessage.withValidated(
                    topicBytes: try #require(topicBuffer.baseAddress),
                    topicLength: topicBuffer.count,
                    payloadBytes: try #require(payloadBuffer.baseAddress),
                    payloadLength: payloadBuffer.count
                ) { message in
                    #expect(message.eventType == .associate)
                    return message.reader().readUUID("ioSourceId")
                }
            }
        }

        #expect(sourceId == UUID16(parsing: "33333333-3333-4333-8333-333333333333"))
    }

    @Test
    func withValidatedRejectsOversizePayloadBeforeInvokingBody() throws {
        let topic = Array("coaty/3/test/ASC/55555555-5555-4555-8555-555555555555".utf8)
        let payload = [UInt8](repeating: 0x20, count: WireBufferConfig.maxPayloadSize + 1)
        var invoked = false
        var caught: Error?

        topic.withUnsafeBufferPointer { topicBuffer in
            payload.withUnsafeBufferPointer { payloadBuffer in
                do {
                    _ = try BorrowedMessage.withValidated(
                        topicBytes: topicBuffer.baseAddress!,
                        topicLength: topicBuffer.count,
                        payloadBytes: payloadBuffer.baseAddress!,
                        payloadLength: payloadBuffer.count
                    ) { _ in invoked = true }
                } catch { caught = error }
            }
        }

        #expect(invoked == false)
        let error = try #require(caught as? WireDecodeError)
        if case .payloadExceedsLimit = error.reason {} else { Issue.record("expected .payloadExceedsLimit, got \(error.reason)") }
    }

    @Test
    func truncatedPayloadReturnsNilInsideSynchronousBorrowScope() throws {
        let topic = Array("coaty/3/test/ASC/55555555-5555-4555-8555-555555555555".utf8)
        let truncatedPayload = Array(#"{"ioSourceId":"33333333-3333-4333-8333-33333333333"#.utf8)

        try topic.withUnsafeBufferPointer { topicBuffer in
            try truncatedPayload.withUnsafeBufferPointer { payloadBuffer in
                try BorrowedMessage.withValidated(
                    topicBytes: try #require(topicBuffer.baseAddress),
                    topicLength: topicBuffer.count,
                    payloadBytes: try #require(payloadBuffer.baseAddress),
                    payloadLength: payloadBuffer.count
                ) { message in
                    let sourceId = message.reader().readUUID("ioSourceId")
                    #expect(sourceId == nil)
                }
            }
        }
    }
}
