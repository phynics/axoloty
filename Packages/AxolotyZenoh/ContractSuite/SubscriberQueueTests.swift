// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing

import AxolotyZenohContract
import CAxolotyZenoh
import CAxolotyZenohTestSupport

/// Receive-queue coverage through the public C façade seam.
///
/// The suite is serialized because the façade owns one fixed session registry
/// for the process. Each receive test uses two local peer sessions, proving
/// callback-to-owned-queue-to-poll delivery without a router.
extension CAxolotyZenohSessionLifecycleTests {
    private func openPeer() async throws -> OpaquePointer {
        for _ in 0..<200 {
            var config = axoloty_zenoh_config_t(
                mode: AXOLOTY_ZENOH_MODE_PEER,
                connect_endpoint: nil,
                connect_endpoint_length: 0,
                multicast_scouting_enabled: true
            )
            var session: OpaquePointer?
            let result = axoloty_zenoh_open(&config, &session)
            if result == AXOLOTY_ZENOH_OK, let session {
                return session
            }
            if result != AXOLOTY_ZENOH_CAPACITY_EXCEEDED {
                Issue.record("Session open failed with result \(result.rawValue)")
                throw SessionOpenTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for a session registry slot")
        throw SessionOpenTimeout()
    }

    private struct SessionOpenTimeout: Error {}

    private func subscribe(_ session: OpaquePointer, to key: [UInt8]) -> axoloty_zenoh_result_t {
        key.withUnsafeBufferPointer { buffer in
            axoloty_zenoh_subscribe(session, buffer.baseAddress, UInt32(buffer.count))
        }
    }

    private func openPublisher() throws -> UnsafeMutableRawPointer {
        try #require(axoloty_zenoh_test_publisher_open())
    }

    private func publish(
        _ publisher: UnsafeMutableRawPointer,
        key: [UInt8],
        payload: [UInt8]
    ) -> Int32 {
        key.withUnsafeBufferPointer { keyBuffer in
            payload.withUnsafeBufferPointer { payloadBuffer in
                axoloty_zenoh_test_publisher_put(
                    publisher,
                    keyBuffer.baseAddress,
                    keyBuffer.count,
                    payloadBuffer.baseAddress,
                    payloadBuffer.count
                )
            }
        }
    }

    private func waitForDepth(_ expected: UInt32, on session: OpaquePointer) async throws -> UInt32 {
        for _ in 0..<200 {
            var depth: UInt32 = 0
            #expect(axoloty_zenoh_queue_depth(session, &depth) == AXOLOTY_ZENOH_OK)
            if depth >= expected {
                return depth
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for receive queue depth \(expected)")
        return 0
    }

    private func poll(_ session: OpaquePointer) -> (axoloty_zenoh_result_t, [UInt8], [UInt8]) {
        var key = [UInt8](repeating: 0, count: Int(AXOLOTY_ZENOH_MAX_KEY_BYTES))
        var payload = [UInt8](repeating: 0, count: Int(AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES))
        var keyLength: UInt32 = 0
        var payloadLength: UInt32 = 0
        let result = key.withUnsafeMutableBufferPointer { keyBuffer in
            payload.withUnsafeMutableBufferPointer { payloadBuffer in
                axoloty_zenoh_poll(
                    session,
                    keyBuffer.baseAddress,
                    UInt32(keyBuffer.count),
                    &keyLength,
                    payloadBuffer.baseAddress,
                    UInt32(payloadBuffer.count),
                    &payloadLength
                )
            }
        }
        return (result, Array(key.prefix(Int(keyLength))), Array(payload.prefix(Int(payloadLength))))
    }

    @Test("a second peer publishes into the owned queue and poll returns copied bytes")
    func subscribePollRoundTripAndUnsubscribe() async throws {
        let contract = try ZenohFacadeContract.load()
        #expect(contract.contractVersion == "1.0.0")
        let receiver = try await openPeer()
        let publisher = try openPublisher()
        let route = Array(contract.vectors.roundTrip.key.utf8)
        var subscriptionKey = route
        #expect(subscribe(receiver, to: subscriptionKey) == AXOLOTY_ZENOH_OK)
        #expect(subscribe(receiver, to: route) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
        subscriptionKey = [0xFF]
        // Peer discovery is asynchronous. Let the two local sessions establish
        // their matching before publishing the first sample.
        try await Task.sleep(for: .milliseconds(250))

        var sourceKey = route
        var sourcePayload = contract.vectors.roundTrip.payload
        #expect(publish(publisher, key: sourceKey, payload: sourcePayload) == 0)
        sourceKey = [0xFF]
        sourcePayload = [0x00]

        #expect(try await waitForDepth(1, on: receiver) == 1)
        var shortKey: [UInt8] = [0]
        var shortPayload: [UInt8] = [0]
        var shortKeyLength: UInt32 = 0
        var shortPayloadLength: UInt32 = 0
        let shortPoll = shortKey.withUnsafeMutableBufferPointer { keyBuffer in
            shortPayload.withUnsafeMutableBufferPointer { payloadBuffer in
                axoloty_zenoh_poll(
                    receiver,
                    keyBuffer.baseAddress,
                    UInt32(keyBuffer.count),
                    &shortKeyLength,
                    payloadBuffer.baseAddress,
                    UInt32(payloadBuffer.count),
                    &shortPayloadLength
                )
            }
        }
        #expect(shortPoll == AXOLOTY_ZENOH_INVALID_ARGUMENT)
        var depthAfterShortPoll: UInt32 = 0
        #expect(axoloty_zenoh_queue_depth(receiver, &depthAfterShortPoll) == AXOLOTY_ZENOH_OK)
        #expect(depthAfterShortPoll == 1)
        let (pollResult, receivedKey, receivedPayload) = poll(receiver)
        #expect(pollResult == AXOLOTY_ZENOH_OK)
        #expect(receivedKey == route)
        #expect(receivedPayload == contract.vectors.roundTrip.payload)
        #expect(poll(receiver).0 == AXOLOTY_ZENOH_QUEUE_EMPTY)

        #expect(publish(publisher, key: route, payload: [0x66]) == 0)
        #expect(try await waitForDepth(1, on: receiver) == 1)
        #expect(axoloty_zenoh_unsubscribe(receiver) == AXOLOTY_ZENOH_OK)
        #expect(axoloty_zenoh_unsubscribe(receiver) == AXOLOTY_ZENOH_NOT_OPEN)
        #expect(poll(receiver).0 == AXOLOTY_ZENOH_QUEUE_EMPTY)
        #expect(publish(publisher, key: route, payload: [0x55]) == 0)
        try await Task.sleep(for: .milliseconds(100))
        var unsubscribedDepth: UInt32 = 0
        #expect(axoloty_zenoh_queue_depth(receiver, &unsubscribedDepth) == AXOLOTY_ZENOH_OK)
        #expect(unsubscribedDepth == 0)
        #expect(subscribe(receiver, to: route) == AXOLOTY_ZENOH_OK)
        try await Task.sleep(for: .milliseconds(250))
        #expect(publish(publisher, key: route, payload: []) == 0)
        #expect(try await waitForDepth(1, on: receiver) == 1)
        let (resubscribedPoll, resubscribedKey, emptyPayload) = poll(receiver)
        #expect(resubscribedPoll == AXOLOTY_ZENOH_OK)
        #expect(resubscribedKey == route)
        #expect(emptyPayload.isEmpty)
        #expect(axoloty_zenoh_close(receiver) == AXOLOTY_ZENOH_OK)
        #expect(axoloty_zenoh_unsubscribe(receiver) == AXOLOTY_ZENOH_NOT_OPEN)
        var closedKey = [UInt8](repeating: 0, count: Int(AXOLOTY_ZENOH_MAX_KEY_BYTES))
        var closedPayload = [UInt8](repeating: 0, count: Int(AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES))
        var closedKeyLength: UInt32 = 0
        var closedPayloadLength: UInt32 = 0
        let closedPoll = closedKey.withUnsafeMutableBufferPointer { keyBuffer in
            closedPayload.withUnsafeMutableBufferPointer { payloadBuffer in
                axoloty_zenoh_poll(
                    receiver,
                    keyBuffer.baseAddress,
                    UInt32(keyBuffer.count),
                    &closedKeyLength,
                    payloadBuffer.baseAddress,
                    UInt32(payloadBuffer.count),
                    &closedPayloadLength
                )
            }
        }
        #expect(closedPoll == AXOLOTY_ZENOH_NOT_OPEN)
        #expect(subscribe(receiver, to: route) == AXOLOTY_ZENOH_NOT_OPEN)
        axoloty_zenoh_test_publisher_close(publisher)
    }

    @Test("each subscriber receives the same publication")
    func multipleSubscribersReceiveSameFrame() async throws {
        let contract = try ZenohFacadeContract.load()
        let firstReceiver = try await openPeer()
        let secondReceiver = try await openPeer()
        let publisher = try openPublisher()
        let vector = contract.vectors.multipleSubscribers
        let route = Array(vector.key.utf8)
        #expect(subscribe(firstReceiver, to: route) == AXOLOTY_ZENOH_OK)
        #expect(subscribe(secondReceiver, to: route) == AXOLOTY_ZENOH_OK)
        try await Task.sleep(for: .milliseconds(250))

        #expect(publish(publisher, key: route, payload: vector.payload) == 0)
        #expect(try await waitForDepth(1, on: firstReceiver) == 1)
        #expect(try await waitForDepth(1, on: secondReceiver) == 1)

        let (firstResult, firstKey, firstPayload) = poll(firstReceiver)
        let (secondResult, secondKey, secondPayload) = poll(secondReceiver)
        #expect(firstResult == AXOLOTY_ZENOH_OK)
        #expect(secondResult == AXOLOTY_ZENOH_OK)
        #expect(firstKey == route)
        #expect(secondKey == route)
        #expect(firstPayload == vector.payload)
        #expect(secondPayload == vector.payload)

        #expect(axoloty_zenoh_close(firstReceiver) == AXOLOTY_ZENOH_OK)
        #expect(axoloty_zenoh_close(secondReceiver) == AXOLOTY_ZENOH_OK)
        axoloty_zenoh_test_publisher_close(publisher)
    }

    @Test("a full queue drops newest exactly once per frame and remains pollable")
    func fullQueueDropsNewest() async throws {
        let contract = try ZenohFacadeContract.load()
        let receiver = try await openPeer()
        let publisher = try openPublisher()
        let vector = contract.vectors.queueOverflow
        let route = Array(vector.key.utf8)
        #expect(vector.acceptedPayloads.count == Int(AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY))
        #expect(vector.expectedDroppedFrameCount == 1)
        #expect(subscribe(receiver, to: route) == AXOLOTY_ZENOH_OK)
        try await Task.sleep(for: .milliseconds(250))

        for payload in vector.acceptedPayloads + [vector.overflowPayload] {
            #expect(publish(publisher, key: route, payload: payload) == 0)
        }
        #expect(try await waitForDepth(UInt32(AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY), on: receiver)
            == UInt32(AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY))
        var dropped: UInt32 = 0
        for _ in 0..<200 {
            #expect(axoloty_zenoh_dropped_frame_count(receiver, &dropped) == AXOLOTY_ZENOH_OK)
            if dropped == vector.expectedDroppedFrameCount { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(dropped == vector.expectedDroppedFrameCount)
        var depth: UInt32 = 0
        #expect(axoloty_zenoh_queue_depth(receiver, &depth) == AXOLOTY_ZENOH_OK)
        #expect(depth == UInt32(AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY))

        for expected in vector.acceptedPayloads {
            let (result, key, payload) = poll(receiver)
            #expect(result == AXOLOTY_ZENOH_OK)
            #expect(key == route)
            #expect(payload == expected)
        }
        #expect(poll(receiver).0 == AXOLOTY_ZENOH_QUEUE_FULL)
        #expect(poll(receiver).0 == AXOLOTY_ZENOH_QUEUE_EMPTY)
        #expect(axoloty_zenoh_close(receiver) == AXOLOTY_ZENOH_OK)
        axoloty_zenoh_test_publisher_close(publisher)
    }

    @Test("maximum key and payload are accepted; maximum plus one is counted and dropped")
    func oversizedFramesAreNotTruncated() async throws {
        let contract = try ZenohFacadeContract.load()
        let receiver = try await openPeer()
        let publisher = try openPublisher()
        #expect(subscribe(receiver, to: Array("**".utf8)) == AXOLOTY_ZENOH_OK)
        try await Task.sleep(for: .milliseconds(250))

        let keyOverflow = contract.vectors.keyOverflow
        let payloadOverflow = contract.vectors.payloadOverflow
        let maxKey = Array((String(repeating: "a/", count: 127) + "aa").utf8)
        let oversizedKey = Array((String(repeating: "a/", count: (keyOverflow.keyLength - 1) / 2) + "a")
            .utf8)
        #expect(maxKey.count == Int(AXOLOTY_ZENOH_MAX_KEY_BYTES))
        #expect(oversizedKey.count == keyOverflow.keyLength)
        let maxPayload = [UInt8](repeating: 0xA5, count: Int(AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES))
        let oversizedPayload = [UInt8](repeating: payloadOverflow.fillByte, count: payloadOverflow.payloadLength)

        #expect(publish(publisher, key: maxKey, payload: maxPayload) == 0)
        #expect(publish(publisher, key: oversizedKey, payload: [keyOverflow.fillByte]) == 0)
        let payloadOverflowKey = Array(String(repeating: "x", count: payloadOverflow.keyLength).utf8)
        #expect(publish(publisher, key: payloadOverflowKey, payload: oversizedPayload)
            == 0)

        #expect(try await waitForDepth(1, on: receiver) == 1)
        var oversized: UInt32 = 0
        for _ in 0..<200 {
            #expect(axoloty_zenoh_oversized_frame_count(receiver, &oversized) == AXOLOTY_ZENOH_OK)
            if oversized == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(oversized == 2)
        let (result, key, payload) = poll(receiver)
        #expect(result == AXOLOTY_ZENOH_OK)
        #expect(key == maxKey)
        #expect(payload == maxPayload)
        #expect(poll(receiver).0 == AXOLOTY_ZENOH_FRAME_TOO_LARGE)
        #expect(poll(receiver).0 == AXOLOTY_ZENOH_FRAME_TOO_LARGE)
        #expect(poll(receiver).0 == AXOLOTY_ZENOH_QUEUE_EMPTY)
        #expect(axoloty_zenoh_close(receiver) == AXOLOTY_ZENOH_OK)
        axoloty_zenoh_test_publisher_close(publisher)
    }
}
