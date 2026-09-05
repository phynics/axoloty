// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol

import AxolotyWire

/// A transport boundary for the host runtime.
///
/// Implementations own networking and invoke `receive` only with copied data.
/// The runtime never exposes borrowed wire views through this protocol.
public protocol AxolotyRuntimeTransport: AnyObject, Sendable {
    /// Starts the transport and installs the owned-frame receive callback.
    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws
    /// Installs a callback for failures after startup has completed.
    ///
    /// The callback is invoked with an owned error value and may be called
    /// from a transport event-loop thread. Implementations must not retain
    /// borrowed protocol data in this callback.
    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async
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
    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async { _ = handler }
    func installSubscriptions(namespace: String) async throws {}
    func removeSubscriptions(namespace: String) async throws {}
    func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification {
        route.length == 0 ? .unrelated : .coaty
    }
}
