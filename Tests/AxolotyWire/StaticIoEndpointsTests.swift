// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Foundation
import Testing

private final class IoValueCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UInt8] = []

    func store(_ value: ByteSlice) {
        lock.lock()
        stored = (0..<value.length).map { value.byte(at: $0)! }
        lock.unlock()
    }

    var value: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Suite
struct StaticIoEndpointsTests {
    private let sourceID = UUID16(parsing: "11111111-1111-4111-8111-111111111111")!
    private let actorID = UUID16(parsing: "22222222-2222-4222-8222-222222222222")!
    private let route = "coaty/3/test/IOV/11111111-1111-4111-8111-111111111111"

    @Test
    func sourceOnlyPublishesWhileAssociatedAndExposesRate() throws {
        var endpoints = StaticIoEndpoints(
            sources: [StaticIoEndpointDescriptor(id: sourceID, valueType: "test.Value", mode: .json, configuredUpdateRate: 100)],
            actors: [], actorHandlers: []
        )
        let associated = dispatchAssociate(&endpoints, source: sourceID, actor: actorID, route: route, rate: 250)
        #expect(associated == .associated)
        let state = try #require(endpoints.sourceState(id: sourceID))
        #expect(state.isAssociated)
        #expect(state.negotiatedUpdateRate == 250)

        var topicOutput = [UInt8](repeating: 0, count: WireBufferConfig.maxTopicLength)
        var payloadOutput = [UInt8](repeating: 0, count: WireBufferConfig.maxPayloadSize)
        let payload = Array("42".utf8)
        let published = payload.withUnsafeBufferPointer { input in
            topicOutput.withUnsafeMutableBufferPointer { topic in
                payloadOutput.withUnsafeMutableBufferPointer { output in
                    endpoints.preparePublication(sourceId: sourceID, payload: ByteSlice(bytes: input.baseAddress!, length: input.count), topic: topic.baseAddress!, topicCapacity: topic.count, outputPayload: output.baseAddress!, payloadCapacity: output.count)
                }
            }
        }
        #expect(published?.topicLength == route.utf8.count)
        #expect(published?.payloadLength == 2)

        // Broker reconnects can replay the retained/control-plane Associate;
        // replay is idempotent and one later disassociation stops publishing.
        #expect(dispatchAssociate(&endpoints, source: sourceID, actor: actorID, route: route, rate: 250) == .associated)
        #expect(dispatchAssociate(&endpoints, source: sourceID, actor: actorID, route: nil, rate: nil) == .disassociated)
        #expect(endpoints.sourceState(id: sourceID)?.isAssociated == false)
    }

    @Test
    func actorDeliversBareJsonAndUnsubscribesOnDisassociation() throws {
        let received = IoValueCapture()
        var endpoints = StaticIoEndpoints(
            sources: [],
            actors: [StaticIoEndpointDescriptor(id: actorID, valueType: "test.Value", mode: .json)],
            actorHandlers: [{ payload in received.store(payload) }]
        )
        #expect(dispatchAssociate(&endpoints, source: sourceID, actor: actorID, route: route, rate: nil) == .associated)
        #expect(dispatch(&endpoints, topic: route, payload: "{\"value\":42}") == .delivered)
        #expect(received.value == Array("{\"value\":42}".utf8))
        #expect(dispatch(&endpoints, topic: route, payload: "not-json") == .rejected)
        #expect(dispatchAssociate(&endpoints, source: sourceID, actor: actorID, route: nil, rate: nil) == .disassociated)
        #expect(dispatch(&endpoints, topic: route, payload: "42") == .unknownEndpoint)
    }

    @Test
    func rawActorPreservesBareBytesAndRejectsUnknownRoute() throws {
        let received = IoValueCapture()
        var endpoints = StaticIoEndpoints(sources: [], actors: [StaticIoEndpointDescriptor(id: actorID, valueType: "test.Raw", mode: .raw)], actorHandlers: [{ payload in received.store(payload) }])
        #expect(dispatchAssociate(&endpoints, source: sourceID, actor: actorID, route: "external/raw", rate: nil) == .associated)
        let raw: [UInt8] = [0, 255, 1]
        #expect(dispatchBytes(&endpoints, topic: "external/raw", payload: raw) == .delivered)
        #expect(received.value == raw)
        #expect(dispatchBytes(&endpoints, topic: "external/other", payload: raw) == .unknownEndpoint)
    }

    @Test
    func rejectsIncompatibleLocalEndpointsBadRatesAndRouteChanges() {
        var endpoints = StaticIoEndpoints(
            sources: [StaticIoEndpointDescriptor(id: sourceID, valueType: "test.JSON", mode: .json)],
            actors: [StaticIoEndpointDescriptor(id: actorID, valueType: "test.Raw", mode: .raw)], actorHandlers: [nil]
        )
        #expect(dispatchAssociate(&endpoints, source: sourceID, actor: actorID, route: route, rate: nil) == .rejected)

        var sourceOnly = StaticIoEndpoints(sources: [StaticIoEndpointDescriptor(id: sourceID, valueType: "test.Value", mode: .raw)], actors: [], actorHandlers: [])
        #expect(dispatchAssociate(&sourceOnly, source: sourceID, actor: actorID, route: route, rate: -1) == .rejected)
        #expect(dispatchAssociate(&sourceOnly, source: sourceID, actor: actorID, route: route, rate: nil) == .associated)
        #expect(dispatchAssociate(&sourceOnly, source: sourceID, actor: actorID, route: "coaty/3/test/IOV/other", rate: nil) == .rejected)
    }

    private func dispatchAssociate(_ endpoints: inout StaticIoEndpoints, source: UUID16, actor: UUID16, route: String?, rate: Int?) -> StaticIoDispatchResult {
        var fields = "{\"ioSourceId\":\"11111111-1111-4111-8111-111111111111\",\"ioActorId\":\"22222222-2222-4222-8222-222222222222\""
        if let route { fields += ",\"associatingRoute\":\"\(route)\"" }
        if let rate { fields += ",\"updateRate\":\(rate)" }
        fields += "}"
        return dispatch(&endpoints, topic: "coaty/3/test/ASC/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", payload: fields)
    }

    private func dispatch(_ endpoints: inout StaticIoEndpoints, topic: String, payload: String) -> StaticIoDispatchResult {
        dispatchBytes(&endpoints, topic: topic, payload: Array(payload.utf8))
    }

    private func dispatchBytes(_ endpoints: inout StaticIoEndpoints, topic: String, payload: [UInt8]) -> StaticIoDispatchResult {
        withBuffers(topic: topic, payload: payload) { topicBytes, topicLength, payloadBytes, payloadLength in
            let message = try! BorrowedMessage.validated(topicBytes: topicBytes, topicLength: topicLength, payloadBytes: payloadBytes, payloadLength: payloadLength)
            if message.eventType == .associate { return endpoints.consumeAssociate(message) }
            return endpoints.consumeIoValue(message)
        }
    }

    private func withBuffers<R>(topic: String, payload: [UInt8], _ body: (UnsafePointer<UInt8>, Int, UnsafePointer<UInt8>, Int) -> R) -> R {
        let topicBytes = Array(topic.utf8)
        return topicBytes.withUnsafeBufferPointer { topicBuffer in
            payload.withUnsafeBufferPointer { payloadBuffer in body(topicBuffer.baseAddress!, topicBuffer.count, payloadBuffer.baseAddress!, payloadBuffer.count) }
        }
    }
}
