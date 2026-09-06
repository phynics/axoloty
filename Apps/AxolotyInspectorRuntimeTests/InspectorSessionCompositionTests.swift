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

    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async {}
    func perform(_ effect: RuntimeTransportEffect) async throws {}
    func stop() async { receive = nil }
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
