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

    private func subscribe(_ session: OpaquePointer, to key: [UInt8]) -> (axoloty_zenoh_result_t, OpaquePointer?) {
        var subscription: OpaquePointer?
        let result = key.withUnsafeBufferPointer { buffer in
            axoloty_zenoh_subscribe(session, buffer.baseAddress, UInt32(buffer.count), &subscription)
        }
        return (result, subscription)
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

    private func waitForDepth(_ expected: UInt32, on session: OpaquePointer, subscription: OpaquePointer) async throws -> UInt32 {
        for _ in 0..<200 {
            var depth: UInt32 = 0
            #expect(axoloty_zenoh_queue_depth(session, subscription, &depth) == AXOLOTY_ZENOH_OK)
            if depth >= expected {
                return depth
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for receive queue depth \(expected)")
        return 0
    }

    /// Retries a peer publication until the subscriber queue proves delivery.
    /// The deadline is the success bound; the short pause only paces retries
    /// and does not assume that peer discovery completes within a fixed delay.
    private func publishUntilDepth(
        _ expected: UInt32,
        publisher: UnsafeMutableRawPointer,
        key: [UInt8],
        payload: [UInt8],
        on session: OpaquePointer,
        subscription: OpaquePointer
    ) async throws(any Error) -> UInt32 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        var nextPublishAt = clock.now

        while clock.now < deadline {
            if clock.now >= nextPublishAt {
                guard publish(publisher, key: key, payload: payload) == 0 else {
                    Issue.record("Peer publisher rejected a retry")
                    return 0
                }
                nextPublishAt = clock.now.advanced(by: .milliseconds(500))
            }

            var depth: UInt32 = 0
            guard axoloty_zenoh_queue_depth(session, subscription, &depth) == AXOLOTY_ZENOH_OK else {
                Issue.record("Failed to read receive queue depth during peer delivery")
                return 0
            }
            if depth >= expected { return depth }

            // Poll delivery state between rate-limited retries. The delay
            // paces checks; only queue depth completes this wait.
            try await Task.sleep(for: .milliseconds(10))
        }

        Issue.record("Timed out retrying peer publication until receive queue depth \(expected)")
        return 0
    }

    private func poll(_ session: OpaquePointer, subscription: OpaquePointer) -> (axoloty_zenoh_result_t, [UInt8], [UInt8]) {
        var key = [UInt8](repeating: 0, count: Int(AXOLOTY_ZENOH_MAX_KEY_BYTES))
        var payload = [UInt8](repeating: 0, count: Int(AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES))
        var keyLength: UInt32 = 0
        var payloadLength: UInt32 = 0
        let result = key.withUnsafeMutableBufferPointer { keyBuffer in
            payload.withUnsafeMutableBufferPointer { payloadBuffer in
                axoloty_zenoh_poll(
                    session,
                    subscription,
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
        #expect(contract.contractVersion == "2.1.0")
        let receiver = try await openPeer()
        let publisher = try openPublisher()
        let route = Array(contract.vectors.roundTrip.key.utf8)
        var subscriptionKey = route
        let (subscribeResult, openedSubscription) = subscribe(receiver, to: subscriptionKey)
        #expect(subscribeResult == AXOLOTY_ZENOH_OK)
        let subscription = try #require(openedSubscription)
        #expect(subscribe(receiver, to: route).0 == AXOLOTY_ZENOH_OK)
        subscriptionKey = [0xFF]
        // Peer discovery is asynchronous. Let the two local sessions establish
        // their matching before publishing the first sample.
        try await Task.sleep(for: .milliseconds(250))

        var sourceKey = route
        var sourcePayload = contract.vectors.roundTrip.payload
        #expect(publish(publisher, key: sourceKey, payload: sourcePayload) == 0)
        sourceKey = [0xFF]
        sourcePayload = [0x00]

        #expect(try await waitForDepth(1, on: receiver, subscription: subscription) == 1)
        var shortKey: [UInt8] = [0]
        var shortPayload: [UInt8] = [0]
        var shortKeyLength: UInt32 = 0
        var shortPayloadLength: UInt32 = 0
        let shortPoll = shortKey.withUnsafeMutableBufferPointer { keyBuffer in
            shortPayload.withUnsafeMutableBufferPointer { payloadBuffer in
                axoloty_zenoh_poll(
                    receiver,
                    subscription,
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
        #expect(axoloty_zenoh_queue_depth(receiver, subscription, &depthAfterShortPoll) == AXOLOTY_ZENOH_OK)
        #expect(depthAfterShortPoll == 1)
        let (pollResult, receivedKey, receivedPayload) = poll(receiver, subscription: subscription)
        #expect(pollResult == AXOLOTY_ZENOH_OK)
        #expect(receivedKey == route)
        #expect(receivedPayload == contract.vectors.roundTrip.payload)
        #expect(poll(receiver, subscription: subscription).0 == AXOLOTY_ZENOH_QUEUE_EMPTY)

        #expect(publish(publisher, key: route, payload: [0x66]) == 0)
        #expect(try await waitForDepth(1, on: receiver, subscription: subscription) == 1)
        #expect(axoloty_zenoh_unsubscribe(receiver, subscription) == AXOLOTY_ZENOH_OK)
        #expect(axoloty_zenoh_unsubscribe(receiver, subscription) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
        #expect(poll(receiver, subscription: subscription).0 == AXOLOTY_ZENOH_INVALID_ARGUMENT)
        #expect(publish(publisher, key: route, payload: [0x55]) == 0)
        try await Task.sleep(for: .milliseconds(100))
        var unsubscribedDepth: UInt32 = 0
        #expect(axoloty_zenoh_queue_depth(receiver, subscription, &unsubscribedDepth) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
        #expect(unsubscribedDepth == 0)
        let (resubscribeResult, resubscribedSubscription) = subscribe(receiver, to: route)
        #expect(resubscribeResult == AXOLOTY_ZENOH_OK)
        let activeSubscription = try #require(resubscribedSubscription)
        try await Task.sleep(for: .milliseconds(250))
        #expect(publish(publisher, key: route, payload: []) == 0)
        #expect(try await waitForDepth(1, on: receiver, subscription: activeSubscription) == 1)
        let (resubscribedPoll, resubscribedKey, emptyPayload) = poll(receiver, subscription: activeSubscription)
        #expect(resubscribedPoll == AXOLOTY_ZENOH_OK)
        #expect(resubscribedKey == route)
        #expect(emptyPayload.isEmpty)
        #expect(axoloty_zenoh_close(receiver) == AXOLOTY_ZENOH_OK)
        #expect(axoloty_zenoh_unsubscribe(receiver, activeSubscription) == AXOLOTY_ZENOH_NOT_OPEN)
        var closedKey = [UInt8](repeating: 0, count: Int(AXOLOTY_ZENOH_MAX_KEY_BYTES))
        var closedPayload = [UInt8](repeating: 0, count: Int(AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES))
        var closedKeyLength: UInt32 = 0
        var closedPayloadLength: UInt32 = 0
        let closedPoll = closedKey.withUnsafeMutableBufferPointer { keyBuffer in
            closedPayload.withUnsafeMutableBufferPointer { payloadBuffer in
                axoloty_zenoh_poll(
                    receiver,
                    activeSubscription,
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
        #expect(subscribe(receiver, to: route).0 == AXOLOTY_ZENOH_NOT_OPEN)
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
        let (firstSubscribeResult, firstSubscription) = subscribe(firstReceiver, to: route)
        let (secondSubscribeResult, secondSubscription) = subscribe(secondReceiver, to: route)
        #expect(firstSubscribeResult == AXOLOTY_ZENOH_OK)
        #expect(secondSubscribeResult == AXOLOTY_ZENOH_OK)
        let firstHandle = try #require(firstSubscription)
        let secondHandle = try #require(secondSubscription)
        try await Task.sleep(for: .milliseconds(250))

        #expect(publish(publisher, key: route, payload: vector.payload) == 0)
        #expect(try await waitForDepth(1, on: firstReceiver, subscription: firstHandle) == 1)
        #expect(try await waitForDepth(1, on: secondReceiver, subscription: secondHandle) == 1)

        let (firstResult, firstKey, firstPayload) = poll(firstReceiver, subscription: firstHandle)
        let (secondResult, secondKey, secondPayload) = poll(secondReceiver, subscription: secondHandle)
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

    @Test("profile shapes and exact routes have independent slots, queues, and removal")
    func concurrentSubscriptionSlots() async throws {
        let contract = try ZenohFacadeContract.load()
        let vectors = contract.vectors.multiSubscription
        let receiver = try await openPeer()
        let publisher = try openPublisher()
        let profileFourKey = Array("coaty/3/contracts/*/*".utf8)
        let profileFiveKey = Array("coaty/3/contracts/*/*/*".utf8)
        let externalKey = Array(vectors.exactExternalRoute.key.utf8)

        let (profileFourResult, profileFourMaybe) = subscribe(receiver, to: profileFourKey)
        let (profileFiveResult, profileFiveMaybe) = subscribe(receiver, to: profileFiveKey)
        let (externalResult, externalMaybe) = subscribe(receiver, to: externalKey)
        #expect(profileFourResult == AXOLOTY_ZENOH_OK)
        #expect(profileFiveResult == AXOLOTY_ZENOH_OK)
        #expect(externalResult == AXOLOTY_ZENOH_OK)
        let profileFour = try #require(profileFourMaybe)
        let profileFive = try #require(profileFiveMaybe)
        let external = try #require(externalMaybe)
        try await Task.sleep(for: .milliseconds(250))

        let four = vectors.profileFourSegments
        #expect(publish(publisher, key: Array(four.key.utf8), payload: four.payload) == 0)
        #expect(try await waitForDepth(1, on: receiver, subscription: profileFour) == 1)
        let (fourResult, fourKey, fourPayload) = poll(receiver, subscription: profileFour)
        #expect(fourResult == AXOLOTY_ZENOH_OK)
        #expect(fourKey == Array(four.key.utf8))
        #expect(fourPayload == four.payload)
        #expect(poll(receiver, subscription: profileFive).0 == AXOLOTY_ZENOH_QUEUE_EMPTY)

        let five = vectors.profileFiveSegments
        #expect(publish(publisher, key: Array(five.key.utf8), payload: five.payload) == 0)
        #expect(try await waitForDepth(1, on: receiver, subscription: profileFive) == 1)
        let (fiveResult, fiveKey, fivePayload) = poll(receiver, subscription: profileFive)
        #expect(fiveResult == AXOLOTY_ZENOH_OK)
        #expect(fiveKey == Array(five.key.utf8))
        #expect(fivePayload == five.payload)

        let overflow = contract.vectors.queueOverflow
        for payload in overflow.acceptedPayloads + [overflow.overflowPayload] {
            #expect(publish(publisher, key: Array(five.key.utf8), payload: payload) == 0)
        }
        var profileFiveDrops: UInt32 = 0
        var profileFourDrops: UInt32 = 0
        for _ in 0..<200 {
            #expect(axoloty_zenoh_dropped_frame_count(receiver, profileFive, &profileFiveDrops) == AXOLOTY_ZENOH_OK)
            #expect(axoloty_zenoh_dropped_frame_count(receiver, profileFour, &profileFourDrops) == AXOLOTY_ZENOH_OK)
            if profileFiveDrops == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(profileFiveDrops == 1)
        #expect(profileFourDrops == 0)
        for _ in overflow.acceptedPayloads {
            #expect(poll(receiver, subscription: profileFive).0 == AXOLOTY_ZENOH_OK)
        }
        #expect(poll(receiver, subscription: profileFive).0 == AXOLOTY_ZENOH_QUEUE_FULL)

        let route = vectors.exactExternalRoute
        #expect(publish(publisher, key: externalKey, payload: route.payload) == 0)
        #expect(try await waitForDepth(1, on: receiver, subscription: profileFour) == 1)
        #expect(try await waitForDepth(1, on: receiver, subscription: external) == 1)
        #expect(poll(receiver, subscription: profileFive).0 == AXOLOTY_ZENOH_QUEUE_EMPTY)
        let (profileExternalResult, profileExternalKey, profileExternalPayload) = poll(receiver, subscription: profileFour)
        #expect(profileExternalResult == AXOLOTY_ZENOH_OK)
        #expect(profileExternalKey == externalKey)
        #expect(profileExternalPayload == route.payload)
        let (externalFrameResult, externalFrameKey, externalFramePayload) = poll(receiver, subscription: external)
        #expect(externalFrameResult == AXOLOTY_ZENOH_OK)
        #expect(externalFrameKey == externalKey)
        #expect(externalFramePayload == route.payload)
        #expect(axoloty_zenoh_unsubscribe(receiver, external) == AXOLOTY_ZENOH_OK)
        #expect(axoloty_zenoh_unsubscribe(receiver, external) == AXOLOTY_ZENOH_INVALID_ARGUMENT)

        #expect(publish(publisher, key: externalKey, payload: [0x7A]) == 0)
        #expect(try await waitForDepth(1, on: receiver, subscription: profileFour) == 1)
        let (afterUnsubscribeResult, afterUnsubscribeKey, afterUnsubscribePayload) = poll(receiver, subscription: profileFour)
        #expect(afterUnsubscribeResult == AXOLOTY_ZENOH_OK)
        #expect(afterUnsubscribeKey == externalKey)
        #expect(afterUnsubscribePayload == [0x7A])
        #expect(poll(receiver, subscription: external).0 == AXOLOTY_ZENOH_INVALID_ARGUMENT)

        for index in 0..<(vectors.maximumSubscribers - 2) {
            let fillerKey = Array("axoloty/contract/fill/\(index)".utf8)
            #expect(subscribe(receiver, to: fillerKey).0 == AXOLOTY_ZENOH_OK)
        }
        #expect(poll(receiver, subscription: external).0 == AXOLOTY_ZENOH_INVALID_ARGUMENT)
        var rejectedHandle: OpaquePointer?
        let fullResult = profileFourKey.withUnsafeBufferPointer { buffer in
            axoloty_zenoh_subscribe(receiver, buffer.baseAddress, UInt32(buffer.count), &rejectedHandle)
        }
        #expect(fullResult == AXOLOTY_ZENOH_CAPACITY_EXCEEDED)
        #expect(rejectedHandle == nil)
        let foreign = OpaquePointer(bitPattern: 0xDEAD_BEEF)!
        #expect(axoloty_zenoh_unsubscribe(receiver, foreign) == AXOLOTY_ZENOH_INVALID_ARGUMENT)

        let profileDepth = try await publishUntilDepth(
            1,
            publisher: publisher,
            key: Array(four.key.utf8),
            payload: [0x6B],
            on: receiver,
            subscription: profileFour
        )
        #expect(profileDepth == 1)
        let (profileResult, profileKey, profilePayload) = poll(receiver, subscription: profileFour)
        #expect(profileResult == AXOLOTY_ZENOH_OK)
        #expect(profileKey == Array(four.key.utf8))
        #expect(profilePayload == [0x6B])
        #expect(poll(receiver, subscription: profileFour).0 == AXOLOTY_ZENOH_QUEUE_EMPTY)
        #expect(poll(receiver, subscription: profileFive).0 == AXOLOTY_ZENOH_QUEUE_EMPTY)
        #expect(axoloty_zenoh_close(receiver) == AXOLOTY_ZENOH_OK)
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
        let (subscribeResult, openedSubscription) = subscribe(receiver, to: route)
        #expect(subscribeResult == AXOLOTY_ZENOH_OK)
        let subscription = try #require(openedSubscription)
        try await Task.sleep(for: .milliseconds(250))

        for payload in vector.acceptedPayloads + [vector.overflowPayload] {
            #expect(publish(publisher, key: route, payload: payload) == 0)
        }
        #expect(try await waitForDepth(UInt32(AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY), on: receiver, subscription: subscription)
            == UInt32(AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY))
        var dropped: UInt32 = 0
        for _ in 0..<200 {
            #expect(axoloty_zenoh_dropped_frame_count(receiver, subscription, &dropped) == AXOLOTY_ZENOH_OK)
            if dropped == vector.expectedDroppedFrameCount { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(dropped == vector.expectedDroppedFrameCount)
        var depth: UInt32 = 0
        #expect(axoloty_zenoh_queue_depth(receiver, subscription, &depth) == AXOLOTY_ZENOH_OK)
        #expect(depth == UInt32(AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY))

        for expected in vector.acceptedPayloads {
            let (result, key, payload) = poll(receiver, subscription: subscription)
            #expect(result == AXOLOTY_ZENOH_OK)
            #expect(key == route)
            #expect(payload == expected)
        }
        #expect(poll(receiver, subscription: subscription).0 == AXOLOTY_ZENOH_QUEUE_FULL)
        #expect(poll(receiver, subscription: subscription).0 == AXOLOTY_ZENOH_QUEUE_EMPTY)
        #expect(axoloty_zenoh_close(receiver) == AXOLOTY_ZENOH_OK)
        axoloty_zenoh_test_publisher_close(publisher)
    }

    @Test("maximum key and payload are accepted; maximum plus one is counted and dropped")
    func oversizedFramesAreNotTruncated() async throws {
        let contract = try ZenohFacadeContract.load()
        let receiver = try await openPeer()
        let publisher = try openPublisher()
        let (subscribeResult, openedSubscription) = subscribe(receiver, to: Array("**".utf8))
        #expect(subscribeResult == AXOLOTY_ZENOH_OK)
        let subscription = try #require(openedSubscription)
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

        #expect(try await waitForDepth(1, on: receiver, subscription: subscription) == 1)
        var oversized: UInt32 = 0
        for _ in 0..<200 {
            #expect(axoloty_zenoh_oversized_frame_count(receiver, subscription, &oversized) == AXOLOTY_ZENOH_OK)
            if oversized == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(oversized == 2)
        let (result, key, payload) = poll(receiver, subscription: subscription)
        #expect(result == AXOLOTY_ZENOH_OK)
        #expect(key == maxKey)
        #expect(payload == maxPayload)
        #expect(poll(receiver, subscription: subscription).0 == AXOLOTY_ZENOH_FRAME_TOO_LARGE)
        #expect(poll(receiver, subscription: subscription).0 == AXOLOTY_ZENOH_FRAME_TOO_LARGE)
        #expect(poll(receiver, subscription: subscription).0 == AXOLOTY_ZENOH_QUEUE_EMPTY)
        #expect(axoloty_zenoh_close(receiver) == AXOLOTY_ZENOH_OK)
        axoloty_zenoh_test_publisher_close(publisher)
    }
}
