// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import Testing

/// The JS → modern direction of the Advertise capability: pinned CoatyJS
/// 2.4.0 is the producer and Axoloty is the consumer that must decode the
/// semantic content of the event, not merely receive bytes on the wire.
///
/// This is the mirror of `AxolotyAdvertiseProducerTests`, which covers
/// modern Swift producing for a CoatyJS consumer.
@MainActor
struct AxolotyAdvertiseConsumerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_JS_TO_MODERN_LIVE"] == "1"))
    func decodesAdvertiseFromCoatyJS() async throws {
        let environment = ProcessInfo.processInfo.environment
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"

        let communication = CommunicationOptions(
            namespace: namespace,
            mqttClientOptions: MQTTClientOptions(host: host, port: port),
            shouldAutoStart: false
        )
        let container = Container.resolve(
            components: Components(controllers: [:], objectTypes: []),
            configuration: Configuration(communication: communication)
        )
        defer { container.shutdown() }

        guard let communicationManager = container.communicationManager else {
            Issue.record("Container did not resolve a communication manager")
            return
        }

        try await container.startAndWaitUntilReady()

        let stream = try await communicationManager.observeAdvertiseStream(
            withObjectType: "com.coaty.test.WireFixture"
        )
        var iterator = stream.makeAsyncIterator()

        // Printed only after the topic subscription is acquired (see
        // `observeAdvertiseStream`), so a live runner can safely start the
        // CoatyJS producer once this line appears in the process log.
        print("{\"state\":\"ready\",\"scenario\":\"coatyjs-advertise\"}")

        // Generous relative to the other reverse scenarios (their JS side
        // waits up to 60s for a producer): the CoatyJS producer process in a
        // live run has to load @coaty/core and connect before it can
        // publish, and that cold start can itself take tens of seconds.
        let snapshot = try await nextAdvertise(&iterator, timeout: .seconds(45))

        // The semantic assertions that make this JS → modern rather than
        // just "a packet was delivered": every protocol-significant field
        // CoatyJS put on the wire must decode to the expected Swift values.
        #expect((snapshot.object.coreType) == .CoatyObject)
        #expect((snapshot.object.objectType) == "com.coaty.test.WireFixture")
        #expect((snapshot.object.objectId) == "11111111-1111-4111-8111-111111111111")
        #expect((snapshot.object.name) == "wire-fixture")

        print("{\"state\":\"ack\",\"scenario\":\"coatyjs-advertise\",\"objectId\":\"\(snapshot.object.objectId)\"}")
    }
}

/// `EventStream.Iterator.next()` is a mutating method, which an escaping task
/// closure cannot call directly on a captured `var`. Boxing it in a class
/// (matching the pattern in `AxolotyCoreProducerTests.swift`) gives the
/// closure a stable reference to mutate instead.
private final class AdvertiseIteratorBox: @unchecked Sendable {
    var iterator: EventStream<AdvertiseEventSnapshot>.Iterator

    init(_ iterator: EventStream<AdvertiseEventSnapshot>.Iterator) {
        self.iterator = iterator
    }
}

private func nextAdvertise(
    _ iterator: inout EventStream<AdvertiseEventSnapshot>.Iterator,
    timeout: Duration
) async throws -> AdvertiseEventSnapshot {
    let box = AdvertiseIteratorBox(iterator)
    defer { iterator = box.iterator }

    return try await withThrowingTaskGroup(of: AdvertiseEventSnapshot.self) { group in
        group.addTask {
            guard let value = await box.iterator.next() else {
                throw AxolotyError.runtime(code: .streamEnded, reason: "Advertise stream ended before a snapshot arrived")
            }
            return value
        }
        group.addTask {
            try await _Concurrency.Task.sleep(for: timeout)
            throw AxolotyError.runtime(code: .timedOut, reason: "Timed out waiting for CoatyJS to publish Advertise")
        }
        guard let value = try await group.next() else {
            throw AxolotyError.runtime(code: .timedOut, reason: "Timed out waiting for CoatyJS to publish Advertise")
        }
        group.cancelAll()
        return value
    }
}
