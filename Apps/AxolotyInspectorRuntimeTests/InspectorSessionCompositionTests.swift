// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
import AxolotyProtocol
import AxolotyWire
import Testing

/// A transport that accepts everything and reaches no network.
private actor StubTransport: AxolotyRuntimeTransport {
    private(set) var started = false
    private var receive: (@Sendable (RuntimeInboundFrame) -> Void)?

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {
        self.receive = receive
        started = true
    }

    func setFailureHandler(_ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void) async {}
    func perform(_ effect: RuntimeTransportEffect) async throws {}
    func stop() async { receive = nil }

    func deliver(_ frame: RuntimeInboundFrame) {
        receive?(frame)
    }
}

/// Records what the session asked its factory to build.
private final class ConfigurationBox: @unchecked Sendable {
    var value: InspectorConnectionConfiguration?
}

/// The session composes without naming a carrier, and hands the factory the
/// configuration it was given.
///
/// Before the composition inversion this could not be written: constructing a
/// session built an MQTT binding, so every inspector test needed a broker.
@Test @MainActor
func inspectorSessionComposesOnASuppliedTransport() throws {
    let configuration = InspectorConnectionConfiguration(
        host: "unused.invalid",
        port: 1883,
        namespace: "test"
    )
    let observed = ConfigurationBox()

    _ = try AxolotyInspectorSession(configuration: configuration) { supplied in
        observed.value = supplied
        return StubTransport()
    }

    #expect(observed.value == configuration)
}

/// A failing factory surfaces as a session construction failure rather than
/// being swallowed into a half-built session.
@Test @MainActor
func inspectorSessionPropagatesTransportFactoryFailure() {
    struct TransportUnavailable: Error {}
    let configuration = InspectorConnectionConfiguration(
        host: "unused.invalid",
        port: 1883,
        namespace: "test"
    )

    #expect(throws: TransportUnavailable.self) {
        _ = try AxolotyInspectorSession(configuration: configuration) { _ in
            throw TransportUnavailable()
        }
    }
}

/// A received Advertise surfaces with its canonical hyphenated source ID.
///
/// The session once formatted source IDs with a private helper that indexed
/// past its sixteen hex pairs, so the first live event trapped.
@Test @MainActor
func inspectorSessionFormatsReceivedSourceIDs() async throws {
    struct AdvertiseTimeout: Error {}
    let configuration = InspectorConnectionConfiguration(
        host: "unused.invalid",
        port: 1883,
        namespace: "test"
    )
    let transport = StubTransport()
    let session = try AxolotyInspectorSession(configuration: configuration) { _ in transport }
    try await session.connect()
    let events = await session.advertiseEvents()

    let sourceID = "0a1b2c3d-4e5f-4061-8293-a4b5c6d7e8f9"
    await transport.deliver(.profile(
        route: "coaty/3/test/ADV:CoatyObject/\(sourceID)",
        payload: Array(#"{"object":{"objectId":"33333333-3333-4333-8333-333333333333","coreType":"CoatyObject","objectType":"com.coaty.test.WireFixture","name":"wire-fixture"}}"#.utf8),
        nowMS: 1
    ))

    let event = try await withThrowingTaskGroup(of: InspectorAdvertiseEvent?.self) { group in
        group.addTask {
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw AdvertiseTimeout()
        }
        defer { group.cancelAll() }
        return try #require(try await group.next() ?? nil)
    }
    #expect(event.sourceId == sourceID)
    #expect(event.object.objectId == "33333333-3333-4333-8333-333333333333")
}

/// The configuration owns its timeout conversion, so composition roots do not
/// each repeat the clamp.
@Test
func connectTimeoutClampsIntoTheTransportRange() {
    func configuration(_ timeout: Duration) -> InspectorConnectionConfiguration {
        InspectorConnectionConfiguration(host: "h", port: 1883, namespace: "n", connectTimeout: timeout)
    }

    #expect(configuration(.seconds(10)).connectTimeoutMilliseconds == 10_000)
    #expect(configuration(.milliseconds(0)).connectTimeoutMilliseconds == 1)
    #expect(configuration(.seconds(-5)).connectTimeoutMilliseconds == 1)
    #expect(configuration(.seconds(600)).connectTimeoutMilliseconds == 120_000)
}
