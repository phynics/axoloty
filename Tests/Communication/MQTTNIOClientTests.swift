// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import NIO
import Testing

@Suite
struct MQTTNIOClientTests {
    @Test
    func validUTF8PayloadReadsByteBufferWithoutLossyDecoding() {
        var validPayload = ByteBufferAllocator().buffer(capacity: 5)
        validPayload.writeBytes([0x48, 0x65, 0x6C, 0x6C, 0x6F])

        var invalidPayload = ByteBufferAllocator().buffer(capacity: 1)
        invalidPayload.writeBytes([0xFF])

        #expect(MQTTNIOClient.validUTF8Payload(from: validPayload) == "Hello")
        #expect(MQTTNIOClient.validUTF8Payload(from: invalidPayload) == nil)
    }

    @Test
    func parsedMessageOwnsTopicMetadataBeforeActorDelivery() async throws {
        var topic = Array("coaty/3/test/ADV:sensors/11111111-1111-4111-8111-111111111111".utf8)
        let parsed = try topic.withUnsafeBufferPointer { buffer in
            let view = TopicView(
                topicBytes: try #require(buffer.baseAddress),
                length: buffer.count
            )
            return ParsedMQTTMessage(topicView: view, payload: "{}")
        }

        // Mutating the source bytes after the scoped TopicView borrow proves
        // ParsedMQTTMessage retained materialized Strings, not borrowed slices.
        topic = Array(repeating: 0x78, count: topic.count)
        #expect(parsed.eventType == .advertise)
        #expect(parsed.eventTypeFilter == "sensors")
        #expect(parsed.namespace == "test")
        #expect(parsed.sourceId == "11111111-1111-4111-8111-111111111111")

        let delivered = await ParsedMessageActor().echo(parsed)
        #expect(delivered == parsed)
    }
}

private actor ParsedMessageActor {
    func echo(_ message: ParsedMQTTMessage) -> ParsedMQTTMessage {
        message
    }
}
