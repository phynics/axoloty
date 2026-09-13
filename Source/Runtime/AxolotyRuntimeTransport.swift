// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol

import AxolotyWire

/// An owned, sendable failure reported by a runtime transport.
///
/// Transport adapters convert foreign errors into this value before invoking
/// the runtime failure callback. The code is stable for programmatic handling;
/// the detail is a human-readable description of the observed failure.
public struct RuntimeTransportFailure: Error, Equatable, Sendable {
    /// The stable runtime category for this failure.
    public let code: AxolotyError.RuntimeErrorCode
    /// A human-readable description of the observed failure.
    public let detail: String

    /// Creates an owned transport failure.
    ///
    /// - Parameters:
    ///   - code: Stable runtime category for this failure.
    ///   - detail: Human-readable description of the observed failure.
    public init(code: AxolotyError.RuntimeErrorCode, detail: String) {
        self.code = code
        self.detail = detail
    }
}

/// An owned MQTT-compatible last-will publication supplied at transport start.
///
/// The runtime builds this message from its lifecycle identity. A transport
/// may install it on its connection, or ignore it when its carrier has no
/// last-will feature.
public struct RuntimeTransportLastWill: Sendable, Equatable {
    /// The exact route on which the broker publishes the will.
    public let topic: String
    /// The copied payload published by the broker.
    public let payload: [UInt8]

    /// Creates a transport last-will publication.
    ///
    /// - Parameters:
    ///   - topic: Exact destination route.
    ///   - payload: Owned payload bytes.
    public init(topic: String, payload: [UInt8]) {
        self.topic = topic
        self.payload = payload
    }
}

/// A transport boundary for the host runtime.
///
/// Implementations own networking and invoke `receive` only with copied data.
/// The runtime never exposes borrowed wire views through this protocol.
public protocol AxolotyRuntimeTransport: AnyObject, Sendable {
    /// Starts the transport and installs the owned-frame receive callback.
    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws
    /// Starts the transport and optionally installs a lifecycle last will.
    func start(
        receive: @escaping @Sendable (RuntimeInboundFrame) -> Void,
        lastWill: RuntimeTransportLastWill?
    ) async throws
    /// Installs a callback for failures after startup has completed.
    ///
    /// The callback is invoked with an owned ``RuntimeTransportFailure`` and
    /// may be called from a transport event-loop thread.
    /// Implementations must wrap foreign failures before invoking it and must not
    /// retain borrowed protocol data in this callback.
    func setFailureHandler(_ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void) async
    /// Applies one owned transport effect in protocol action order.
    ///
    /// - Parameter effect: A finished publication, or an exact external-route
    ///   lifecycle effect. Routes arrive resolved; the transport supplies no
    ///   profile knowledge to address them.
    /// - Throws: A transport error when the effect cannot be applied.
    func perform(_ effect: RuntimeTransportEffect) async throws
    /// Stops the transport and releases its callbacks.
    func stop() async

    /// Installs binding subscriptions before identity is advertised.
    ///
    /// Deliberately not generalized. MQTT implements this as a server-side
    /// wildcard subscription, which is a broker capability rather than a
    /// concept every carrier shares; renaming it into transport-neutral
    /// vocabulary would assert a commonality no second transport has yet
    /// demonstrated. Both methods default to no-ops, so an adapter without
    /// the concept simply does not implement them.
    func installSubscriptions(namespace: String) async throws
    /// Removes binding subscriptions during graceful shutdown.
    func removeSubscriptions(namespace: String) async throws
    /// Classifies an association route using binding-owned knowledge.
    ///
    /// The borrowed route is valid only for this synchronous call. The
    /// transport must not retain it or impose a profile-wide route grammar.
    func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification
}

public extension AxolotyRuntimeTransport {
    /// Starts the transport with an optional lifecycle last will.
    ///
    /// Existing adapters that do not support a broker last will can continue
    /// implementing ``start(receive:)``; the default implementation ignores
    /// this message and preserves that behavior.
    ///
    /// - Parameters:
    ///   - receive: Callback for copied inbound frames.
    ///   - lastWill: Optional publication for an unclean disconnect.
    /// - Throws: The transport's startup error.
    func start(
        receive: @escaping @Sendable (RuntimeInboundFrame) -> Void,
        lastWill: RuntimeTransportLastWill?
    ) async throws {
        try await start(receive: receive)
    }

    func setFailureHandler(_ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void) async { _ = handler }
    func installSubscriptions(namespace: String) async throws {}
    func removeSubscriptions(namespace: String) async throws {}
    func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification {
        route.length == 0 ? .unrelated : .coaty
    }
}
