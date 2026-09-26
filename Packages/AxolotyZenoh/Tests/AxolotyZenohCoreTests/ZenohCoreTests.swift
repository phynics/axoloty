// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing

import CAxolotyZenoh
import CAxolotyZenohTestSupport
import AxolotyWire
@testable import AxolotyZenohCore

/// Public Core seam tests share the process-wide, unlocked C session registry.
@Suite("Axoloty Zenoh Core", .serialized)
struct AxolotyZenohCoreTests {
    @Test("every C result maps to a distinct Swift result")
    func exhaustiveResultTranslation() {
        let cases: [(axoloty_zenoh_result_t, ZenohResult)] = [
            (AXOLOTY_ZENOH_OK, .success),
            (AXOLOTY_ZENOH_INVALID_ARGUMENT, .invalidArgument),
            (AXOLOTY_ZENOH_NOT_OPEN, .notOpen),
            (AXOLOTY_ZENOH_CAPACITY_EXCEEDED, .capacityExceeded),
            (AXOLOTY_ZENOH_TRANSPORT_ERROR, .transportError),
            (AXOLOTY_ZENOH_QUEUE_EMPTY, .queueEmpty),
            (AXOLOTY_ZENOH_QUEUE_FULL, .queueFull),
            (AXOLOTY_ZENOH_FRAME_TOO_LARGE, .frameTooLarge),
        ]

        for (cResult, expected) in cases {
            #expect(ZenohResult(cResult: cResult) == expected)
        }
        for left in cases.indices {
            for right in cases.indices where right > left {
                #expect(cases[left].1 != cases[right].1)
            }
        }
    }

    @Test("open, publish, and close use the synchronous borrowed-byte API")
    func sessionLifecycleAndPublish() {
        var session = ZenohSession()
        #expect(session.open(configuration: ZenohConfiguration(mode: .peer)) == .success)
        #expect(session.open(configuration: ZenohConfiguration(mode: .peer)) == .invalidArgument)

        let published = withSlice("axoloty/core/publish") { key in
            withSlice("payload") { payload in
                session.publish(key: key, payload: payload)
            }
        }
        #expect(published == .success)

        let oversized = withSlice("x") { key in
            let payload = ByteSlice(bytes: UnsafePointer<UInt8>(bitPattern: 1)!, length: 2049)
            return session.publish(key: key, payload: payload)
        }
        #expect(oversized == .invalidArgument)
        #expect(session.close() == .success)
        #expect(session.close() == .notOpen)
        #expect(session.publish(key: .empty, payload: .empty) == .notOpen)
    }

    @Test("poll copies a peer frame into fixed storage")
    func pollsFrameIntoStorage() async throws {
        var receiver = ZenohSession()
        let configuration = ZenohConfiguration(mode: .peer, multicastScoutingEnabled: true)
        #expect(receiver.open(configuration: configuration) == .success)
        let subscription = withSlice("axoloty/core/**") { receiver.subscribe(key: $0) }
        #expect(subscription == .success)

        guard let publisher = axoloty_zenoh_test_publisher_open() else {
            Issue.record("Could not open the local Zenoh test publisher")
            #expect(receiver.close() == .success)
            return
        }
        defer { axoloty_zenoh_test_publisher_close(publisher) }

        try await Task.sleep(for: .milliseconds(250))
        let key = Array("axoloty/core/frame".utf8)
        let payload: [UInt8] = [0x00, 0x41, 0x80, 0xFF]
        let putResult = key.withUnsafeBufferPointer { keyBuffer in
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
        #expect(putResult == 0)

        var storage = ZenohFrameStorage()
        var pollResult = receiver.poll(into: &storage)
        for _ in 0..<200 where pollResult == .result(.queueEmpty) {
            try await Task.sleep(for: .milliseconds(10))
            pollResult = receiver.poll(into: &storage)
        }

        #expect(pollResult == .frame(ZenohFrame(keyLength: key.count, payloadLength: payload.count)))
        #expect(storage.storedKeyLength == key.count)
        #expect(storage.storedPayloadLength == payload.count)
        storage.withKeyBytes { storedKey in
            key.withUnsafeBufferPointer { keyBuffer in
                #expect(storedKey == ByteSlice(bytes: keyBuffer.baseAddress!, length: keyBuffer.count))
            }
        }
        storage.withPayloadBytes { storedPayload in
            payload.withUnsafeBufferPointer { payloadBuffer in
                #expect(storedPayload == ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count))
            }
        }

        let oversizedPayload = [UInt8](repeating: 0xA5, count: ZenohFrameStorage.payloadCapacity + 1)
        let oversizedPut = key.withUnsafeBufferPointer { keyBuffer in
            oversizedPayload.withUnsafeBufferPointer { payloadBuffer in
                axoloty_zenoh_test_publisher_put(
                    publisher,
                    keyBuffer.baseAddress,
                    keyBuffer.count,
                    payloadBuffer.baseAddress,
                    payloadBuffer.count
                )
            }
        }
        #expect(oversizedPut == 0)
        pollResult = receiver.poll(into: &storage)
        for _ in 0..<200 where pollResult == .result(.queueEmpty) {
            try await Task.sleep(for: .milliseconds(10))
            pollResult = receiver.poll(into: &storage)
        }
        #expect(pollResult == .result(.frameTooLarge))
        #expect(storage.storedKeyLength == 0)
        #expect(storage.storedPayloadLength == 0)
        #expect(receiver.unsubscribe() == .success)
        #expect(receiver.close() == .success)
    }

    @Test("storage capacities match fixed receive bounds and reject oversized publish views")
    func fixedStorageBounds() {
        #expect(MemoryLayout<ZenohFrameStorage>.size >= 2304)
        #expect(ZenohFrameStorage.keyCapacity == Int(AXOLOTY_ZENOH_MAX_KEY_BYTES))
        #expect(ZenohFrameStorage.payloadCapacity == Int(AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES))

        var session = ZenohSession()
        #expect(session.open(configuration: ZenohConfiguration(mode: .peer)) == .success)
        let result = withSlice("axoloty/core/bounds") { key in
            let tooLong = ByteSlice(bytes: UnsafePointer<UInt8>(bitPattern: 1)!, length: 2049)
            return session.publish(key: key, payload: tooLong)
        }
        #expect(result == .invalidArgument)
        #expect(session.close() == .success)
    }

    @Test("dropping a session releases its façade slot")
    func droppedSessionClosesHandle() {
        do {
            var session = ZenohSession()
            #expect(session.open(configuration: ZenohConfiguration(mode: .peer)) == .success)
        }

        var replacement = ZenohSession()
        #expect(replacement.open(configuration: ZenohConfiguration(mode: .peer)) == .success)
        #expect(replacement.close() == .success)
    }

    private func withSlice<R>(_ value: StaticString, _ body: (ByteSlice) -> R) -> R {
        body(ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount))
    }

}
