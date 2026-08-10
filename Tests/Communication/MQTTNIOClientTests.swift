// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
@preconcurrency import MQTTNIO
import Foundation
import NIO
import Testing
import AxolotyWire

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
    func hostIngressRoutesValidAdvertisePayloadAboveEmbeddedLimit() async throws {
        let object = CoatyObject(
            coreType: .CoatyObject,
            objectType: "com.example.LargeObject",
            objectId: try #require(CoatyUUID(uuidString: "22222222-2222-4222-8222-222222222222")),
            name: String(repeating: "n", count: WireBufferConfig.maxPayloadSize)
        )
        let event = try AdvertiseEvent.with(object: object)
        let payload = try HostWireAdapter.encodeEvent(event)
        #expect(payload.count > WireBufferConfig.maxPayloadSize)

        let (client, streams) = makeHostIngressClient()
        let typedStream = await streams.advertiseFamily.subscribe(
            for: AdvertiseKey(eventTypeFilter: "sensors")
        )
        var typedIterator = typedStream.makeAsyncIterator()

        client.handlePublish(.success(publishInfo(payload: payload)))

        let snapshot = try await nextValue(&typedIterator, timeout: .milliseconds(100))
        #expect(snapshot.object.objectId == object.objectId.string)
        #expect(snapshot.object.name == object.name)
    }

    @Test
    func hostAdapterRejectsMalformedPayloadAboveHostLimitBeforeJSONDecoding() {
        let payload = [UInt8](repeating: 0x7B, count: HostWirePayloadLimits.maxPayloadSize + 1)
        do {
            _ = try HostWireAdapter.decodeEvent(from: payload, eventType: .advertise)
            Issue.record("oversized host payload was accepted")
        } catch let error as AxolotyError {
            guard case let .decodingFailure(type, reason, payload) = error else {
                Issue.record("expected structured decodingFailure, got \(error)")
                return
            }
            #expect(type == WireEventType.advertise.rawValue)
            #expect(reason == "payload exceeds the 16 MiB host limit")
            #expect(payload == nil)
        } catch {
            Issue.record("expected AxolotyError, got \(error)")
        }
    }

    @Test
    func hostAdapterConvertsEveryOversizedWireEventShape() throws {
        for fixture in oversizedHostFallbackFixtures() {
            let payload = Array(fixture.json.utf8)
            #expect(payload.count > WireBufferConfig.maxPayloadSize)
            let event = try HostWireAdapter.decodeEvent(from: payload, eventType: fixture.type)
            #expect(try canonicalJSON(encodeOwnedEvent(event)) == canonicalJSON(payload))
        }
    }

    @Test
    func hostIngressPreservesOversizedRawAndJSONIoValues() async throws {
        let rawPayload = [UInt8](repeating: 0xA5, count: WireBufferConfig.maxPayloadSize + 1)
        let jsonPayload = Array("{\"value\":\"\(String(repeating: "x", count: WireBufferConfig.maxPayloadSize))\"}".utf8)
        let (client, streams) = makeHostIngressClient()
        let stream = await streams.ioValues.subscribe()
        var iterator = stream.makeAsyncIterator()

        client.handlePublish(.success(publishInfo(payload: rawPayload, topic: hostIoValueTopic)))
        client.handlePublish(.success(publishInfo(payload: jsonPayload, topic: hostIoValueTopic)))

        #expect(try await nextValue(&iterator, timeout: .milliseconds(100)).payload == rawPayload)
        #expect(try await nextValue(&iterator, timeout: .milliseconds(100)).payload == jsonPayload)
    }

    @Test
    func hostIngressRejectsPayloadAboveHostLimitBeforeDelivery() async throws {
        let (client, streams) = makeHostIngressClient()
        let stream = await streams.rawMQTTMessages.subscribe()
        var iterator = stream.makeAsyncIterator()
        client.handlePublish(.success(publishInfo(
            payload: [UInt8](repeating: 0, count: HostWirePayloadLimits.maxPayloadSize + 1)
        )))

        do {
            _ = try await nextValue(&iterator, timeout: .milliseconds(100))
            Issue.record("payload above the host limit was delivered")
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
            return ParsedMQTTMessage(
                topicView: view,
                event: .advertise(.init(object: Array(#"{"objectId":"22222222-2222-4222-8222-222222222222","coreType":"CoatyObject","objectType":"coaty.CoatyObject","name":"test"}"#.utf8), privateData: nil)),
                payload: Array("{}".utf8)
            )
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

    @Test
    func broadOneWaySubscriptionRoutesOnlyAdvertiseToAdvertiseAll() async throws {
        let (_, streams) = makeHostIngressClient()
        let advertiseStream = await streams.advertiseAll.subscribe()
        var advertiseIterator = advertiseStream.makeAsyncIterator()
        let deadvertiseStream = await streams.deadvertise.subscribe()
        var deadvertiseIterator = deadvertiseStream.makeAsyncIterator()
        let sourceId = "11111111-1111-4111-8111-111111111111"
        let objectId = "22222222-2222-4222-8222-222222222222"
        let topic = "coaty/3/test/DAD/\(sourceId)"
        let topicBytes = Array(topic.utf8)
        let payload = #"{"objectIds":["22222222-2222-4222-8222-222222222222"]}"#
        let payloadBytes = Array(payload.utf8)
        let parsed = try topicBytes.withUnsafeBufferPointer { buffer in
            ParsedMQTTMessage(
                topicView: TopicView(
                    topicBytes: try #require(buffer.baseAddress),
                    length: buffer.count
                ),
                event: .deadvertise(.init(objectIds: Array(#"["22222222-2222-4222-8222-222222222222"]"#.utf8))),
                payload: payloadBytes
            )
        }

        await MQTTNIOClient.routeParsedMessage(parsed: parsed, into: streams)

        let deadvertise = try await nextValue(&deadvertiseIterator, timeout: .milliseconds(100))
        #expect(deadvertise.objectIds == [objectId])
        do {
            _ = try await nextValue(&advertiseIterator, timeout: .milliseconds(100))
            Issue.record("non-Advertise one-way event was routed to advertiseAll")
        } catch {
        }
    }
}

private struct OversizedHostFallbackFixture {
    let type: WireEventType
    let json: String
}

private func oversizedHostFallbackFixtures() -> [OversizedHostFallbackFixture] {
    let large = String(repeating: "x", count: 700)
    let object = "{\"coreType\":\"CoatyObject\",\"objectType\":\"coaty.test.Large\",\"objectId\":\"22222222-2222-4222-8222-222222222222\",\"name\":\"\(large)\"}"
    let objectIds = Array(repeating: "\"22222222-2222-4222-8222-222222222222\"", count: 24).joined(separator: ",")
    let bytes = Array(repeating: "1", count: 320).joined(separator: ",")

    return [
        .init(type: .advertise, json: "{\"object\":\(object)}"),
        .init(type: .deadvertise, json: "{\"objectIds\":[\(objectIds)]}"),
        .init(type: .channel, json: "{\"object\":\(object)}"),
        .init(type: .associate, json: "{\"ioSourceId\":\"33333333-3333-4333-8333-333333333333\",\"ioActorId\":\"44444444-4444-4444-8444-444444444444\",\"associatingRoute\":\"\(large)\"}"),
        .init(type: .ioValue, json: "{\"payload\":[\(bytes)]}"),
        .init(type: .discover, json: "{\"externalId\":\"\(large)\"}"),
        .init(type: .resolve, json: "{\"object\":\(object)}"),
        .init(type: .query, json: "{\"objectTypes\":[\"\(large)\"],\"objectFilter\":{},\"objectJoinConditions\":{\"localProperty\":\"ref\",\"asProperty\":\"related\"}}"),
        .init(type: .retrieve, json: "{\"objects\":[\(object)]}"),
        .init(type: .update, json: "{\"object\":\(object)}"),
        .init(type: .complete, json: "{\"object\":\(object)}"),
        .init(type: .call, json: "{\"parameters\":{\"value\":\"\(large)\"},\"filter\":{}}"),
        .init(type: .returnEvent, json: "{\"result\":{\"value\":\"\(large)\"},\"executionInfo\":{\"trace\":\"\(large)\"},\"error\":{\"code\":7,\"message\":\"\(large)\"}}"),
    ]
}

private func encodeOwnedEvent(_ event: OwnedWireEvent) throws -> [UInt8] {
    var output = [UInt8](repeating: 0, count: 8 * 1_024)
    let count = try output.withUnsafeMutableBufferPointer { buffer in
        var writer = WireWriter(buffer: try #require(buffer.baseAddress), capacity: buffer.count)
        try event.encode(to: &writer)
        return writer.position
    }
    output.removeSubrange(count...)
    return output
}

private func canonicalJSON(_ bytes: [UInt8]) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: Data(bytes))
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private let hostIngressTopic = "coaty/3/test/ADV:sensors/11111111-1111-4111-8111-111111111111"
private let hostIoValueTopic = "coaty/3/test/IOV/22222222-2222-4222-8222-222222222222"

private func publishInfo(payload: [UInt8], topic: String = hostIngressTopic) -> MQTTPublishInfo {
    var buffer = ByteBufferAllocator().buffer(capacity: payload.count)
    buffer.writeBytes(payload)
    return MQTTPublishInfo(
        qos: .atMostOnce,
        retain: false,
        topicName: topic,
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
        advertiseAll: Broadcast(mode: .event),
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
