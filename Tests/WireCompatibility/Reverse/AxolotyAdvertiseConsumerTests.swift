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
        try signalLiveReadiness(environment: environment)
        emitLiveState("{\"state\":\"ready\",\"scenario\":\"coatyjs-advertise\"}")

        // The CoatyJS producer process in a live container run has to load
        // @coaty/core and connect before it can publish. Its cold start can
        // exceed the old 45-second deadline even after this subscriber has
        // acquired its topic, causing an unsubscribe immediately before the
        // matching publish arrives.
        let snapshot = try await nextAdvertise(&iterator, timeout: .seconds(120))

        // The semantic assertions that make this JS → modern rather than
        // just "a packet was delivered": every protocol-significant field
        // CoatyJS put on the wire must decode to the expected Swift values.
        #expect((snapshot.object.coreType) == .CoatyObject)
        #expect((snapshot.object.objectType) == "com.coaty.test.WireFixture")
        #expect((snapshot.object.objectId) == "11111111-1111-4111-8111-111111111111")
        #expect((snapshot.object.name) == "wire-fixture")

        emitLiveState("{\"state\":\"ack\",\"scenario\":\"coatyjs-advertise\",\"objectId\":\"\(snapshot.object.objectId)\"}")
    }
}

/// Awaits the next Advertise snapshot, racing the pull against `timeout` via
/// the shared `nextValue` (which holds the iterator in an actor). Any failure
/// — stream ended or timeout — surfaces as `AxolotyError.runtime` with a
/// scenario-specific reason.
private func nextAdvertise(
    _ iterator: inout AsyncStream<AdvertiseEventSnapshot>.Iterator,
    timeout: Duration
) async throws -> AdvertiseEventSnapshot {
    do {
        return try await nextValue(&iterator, timeout: timeout)
    } catch is CancellationError {
        throw AxolotyError.runtime(code: .streamEnded, reason: "Advertise stream ended before a snapshot arrived")
    } catch {
        throw AxolotyError.runtime(code: .timedOut, reason: "Timed out waiting for CoatyJS to publish Advertise")
    }
}

/// Signals that the live consumer has acquired its MQTT subscription.
///
/// Swift Testing captures both stdout and stderr until a test exits, so a
/// detached container cannot use either stream as a readiness handshake. The
/// runner mounts a signal directory and observes this file instead.
private func signalLiveReadiness(environment: [String: String]) throws {
    guard let readyFile = environment["WIRE_READY_FILE"] else {
        return
    }
    try Data("ready\n".utf8).write(to: URL(fileURLWithPath: readyFile), options: .atomic)
}

/// Writes a live-harness state line to stderr for the final runner log.
///
/// The runner checks acknowledgement only after the test exits, when Swift
/// Testing has released captured output.
private func emitLiveState(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
