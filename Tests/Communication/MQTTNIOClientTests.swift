// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
@preconcurrency import MQTTNIO
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
    func hostIngressDropsInvalidUTF8WithoutYieldingBorrowedData() async throws {
        let (client, streams) = makeHostIngressClient()
        let rawStream = await streams.rawMQTTMessages.subscribe()
        var iterator = rawStream.makeAsyncIterator()
        let parsedStream = await streams.parsedMQTTMessages.subscribe()
        var parsedIterator = parsedStream.makeAsyncIterator()
        let info = publishInfo(payload: [0xFF])

        client.handlePublish(.success(info))

        let raw = try await nextValue(&iterator, timeout: .milliseconds(100))
        #expect(raw.payload == [0xFF])
        do {
            _ = try await nextValue(&parsedIterator, timeout: .milliseconds(100))
            Issue.record("invalid UTF-8 payload was delivered to parsed ingress")
        } catch {
        }
    }

    @Test
    func hostIngressDropsOversizedPayloadWithoutTrapping() async throws {
        let (client, streams) = makeHostIngressClient()
        let rawStream = await streams.rawMQTTMessages.subscribe()
        var iterator = rawStream.makeAsyncIterator()
        let typedStream = await streams.advertiseFamily.subscribe(for: AdvertiseKey(eventTypeFilter: "sensors"))
        var typedIterator = typedStream.makeAsyncIterator()
        let info = publishInfo(payload: Array(repeating: 0x20, count: WireBufferConfig.maxPayloadSize + 1))

        client.handlePublish(.success(info))

        let raw = try await nextValue(&iterator, timeout: .milliseconds(100))
        #expect(raw.payload.count == WireBufferConfig.maxPayloadSize + 1)
        do {
            _ = try await nextValue(&typedIterator, timeout: .milliseconds(100))
            Issue.record("oversized malformed payload was routed as a typed event")
        } catch {
        }
    }

    @Test
    func hostIngressCopiesTruncatedPayloadWithinItsScope() async throws {
        let (client, streams) = makeHostIngressClient()
        let rawStream = await streams.rawMQTTMessages.subscribe()
        var iterator = rawStream.makeAsyncIterator()
        let typedStream = await streams.advertiseFamily.subscribe(for: AdvertiseKey(eventTypeFilter: "sensors"))
        var typedIterator = typedStream.makeAsyncIterator()
        var payload = ByteBufferAllocator().buffer(capacity: 15)
        payload.writeBytes(Array(#"{"objectType":""#.utf8))
        let info = MQTTPublishInfo(
            qos: .atMostOnce,
            retain: false,
            topicName: hostIngressTopic,
            payload: payload,
            properties: MQTTProperties()
        )

        client.handlePublish(.success(info))
        payload.clear()

        let delivered = try await nextValue(&iterator, timeout: .milliseconds(100))
        #expect(delivered.payload == Array(#"{"objectType":""#.utf8))
        do {
            _ = try await nextValue(&typedIterator, timeout: .milliseconds(100))
            Issue.record("truncated payload was routed as a typed event")
        } catch {
        }
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

private let hostIngressTopic = "coaty/3/test/ADV:sensors/11111111-1111-4111-8111-111111111111"

private func publishInfo(payload: [UInt8]) -> MQTTPublishInfo {
    var buffer = ByteBufferAllocator().buffer(capacity: payload.count)
    buffer.writeBytes(payload)
    return MQTTPublishInfo(
        qos: .atMostOnce,
        retain: false,
        topicName: hostIngressTopic,
        payload: buffer,
        properties: MQTTProperties()
    )
}

private func makeHostIngressClient() -> (MQTTNIOClient, CommunicationStreams) {
    let options = MQTTClientOptions(
        host: "127.0.0.1",
        port: 1883,
        shouldTryMDNSDiscovery: false,
        autoReconnect: false
    )
    options.clientId = "host-ingress-test"
    let streams = CommunicationStreams(
        communicationState: Broadcast(mode: .state),
        operatingState: Broadcast(mode: .state),
        rawMQTTMessages: Broadcast(mode: .event),
        parsedMQTTMessages: Broadcast(mode: .event),
        ioValues: Broadcast(mode: .event),
        ioStateFamily: BroadcastFamily(mode: .state),
        associateFamily: BroadcastFamily(mode: .event),
        advertiseFamily: BroadcastFamily(mode: .event),
        deadvertise: Broadcast(mode: .event),
        discover: Broadcast(mode: .event),
        query: Broadcast(mode: .event),
        callFamily: BroadcastFamily(mode: .event),
        updateFamily: BroadcastFamily(mode: .event),
        channelFamily: BroadcastFamily(mode: .event),
        responseFamily: BroadcastFamily(mode: .event)
    )
    let client = MQTTNIOClient(mqttClientOptions: options, delegate: HostIngressDelegate())
    client.setStreams(streams)
    return (client, streams)
}

private struct HostIngressDelegate: CommunicationClientDelegate {
    func didReceiveStart() {}
}

private actor ParsedMessageActor {
    func echo(_ message: ParsedMQTTMessage) -> ParsedMQTTMessage {
        message
    }
}
