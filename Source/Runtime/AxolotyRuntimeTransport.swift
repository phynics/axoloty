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

/// Optional features supported by a transport adapter.
///
/// Failure reporting, route classification, and ordered effects are required
/// by ``AxolotyRuntimeTransport``. This set reports only features that an
/// adapter may omit. The value must remain unchanged for the lifetime of one
/// transport instance.
public struct RuntimeTransportCapabilities: OptionSet, Sendable {
    /// The adapter can install a broker-owned last-will publication.
    public static let lastWill = Self(rawValue: 1 << 0)
    /// The adapter reports recovery after a recoverable transport failure.
    public static let recoveryNotifications = Self(rawValue: 1 << 1)
    /// The adapter records receive, publish, session, and subscription counters.
    public static let activityCounters = Self(rawValue: 1 << 2)
    /// The adapter manages bounded namespace-wide profile subscriptions.
    public static let profileInterest = Self(rawValue: 1 << 3)
    /// The adapter manages exact external-route subscriptions.
    public static let externalRouteSubscriptions = Self(rawValue: 1 << 4)

    /// The encoded optional-feature set.
    public let rawValue: UInt8

    /// Creates a transport capability set from its bit representation.
    ///
    /// - Parameter rawValue: Bits for the optional transport features.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
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

    /// Creates a bounded transport last-will publication.
    ///
    /// - Parameters:
    ///   - topic: A nonempty route within the wire route limit.
    ///   - payload: Owned payload bytes within the wire payload limit.
    /// - Throws: ``AxolotyError/invalidArgument(argument:reason:)`` when a
    ///   value exceeds the wire bounds or the topic is empty.
    public init(topic: String, payload: [UInt8]) throws(AxolotyError) {
        try validateRuntimeTransportMessage(route: topic, payload: payload, routeArgument: "topic")
        self.topic = topic
        self.payload = payload
    }
}

/// A transport boundary for the host runtime.
///
/// Implementations own networking and invoke `receive` only with copied,
/// bounded frame data. The runtime never exposes borrowed wire views through
/// this protocol. Runtime effects arrive serially and are bounded by the
/// runtime's reported payload capacity and `WireBufferConfig.maxTopicLength`.
public protocol AxolotyRuntimeTransport: AnyObject, Sendable {
    /// The immutable optional features supported by this adapter.
    var capabilities: RuntimeTransportCapabilities { get }
    /// The single wire profile this binding carries.
    ///
    /// Each binding selects exactly one profile at composition time; the
    /// runtime never negotiates or switches profiles per message.
    var wireProfile: WireProfile { get }

    /// Starts the transport and installs the owned-frame receive callback.
    ///
    /// Callbacks may arrive on transport-owned threads. The adapter must copy
    /// and bound every route and payload before invoking `receive`. If
    /// ``RuntimeTransportCapabilities/lastWill`` is absent, the adapter must
    /// ignore `lastWill`.
    ///
    /// - Parameters:
    ///   - receive: Callback for copied inbound frames.
    ///   - lastWill: Optional publication for an unclean disconnect.
    /// - Throws: ``AxolotyError`` when startup fails.
    func start(
        receive: @escaping @Sendable (RuntimeInboundFrame) -> Void,
        lastWill: RuntimeTransportLastWill?
    ) async throws(AxolotyError)

    /// Installs a callback for failures after startup has completed.
    ///
    /// The callback is invoked with an owned ``RuntimeTransportFailure`` and
    /// may be called from a transport event-loop thread. Every adapter must
    /// report post-start failures through this callback. Wrap foreign errors
    /// before invoking it and do not retain borrowed protocol data.
    ///
    /// - Parameter handler: Callback invoked with each post-start failure.
    func setFailureHandler(_ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void) async

    /// Installs a callback when a transport that reported a recoverable failure is ready again.
    ///
    /// Implementations that advertise
    /// ``RuntimeTransportCapabilities/recoveryNotifications`` must invoke this
    /// callback after recovery. Other adapters may ignore it.
    ///
    /// - Parameter handler: Callback invoked after the failure episode recovers.
    func setRecoveryHandler(_ handler: @escaping @Sendable () -> Void) async

    /// Installs the runtime-owned bounded sink for transport activity counters.
    ///
    /// Adapters that advertise ``RuntimeTransportCapabilities/activityCounters``
    /// update the sink from their serialized or synchronized paths. Other
    /// adapters may ignore it.
    ///
    /// - Parameter diagnostics: Shared fixed-size counter sink.
    func setDiagnostics(_ diagnostics: RuntimeTransportDiagnostics) async

    /// Applies one owned transport effect in protocol action order.
    ///
    /// - Parameter effect: A finished publication, or an exact external-route
    ///   lifecycle effect. Routes arrive resolved; the transport supplies no
    ///   profile knowledge to address them. Adapters that do not advertise
    ///   ``RuntimeTransportCapabilities/externalRouteSubscriptions`` must reject
    ///   external-route effects with an unsupported-capability error. The
    ///   runtime awaits each effect before offering the next one; adapters must
    ///   preserve that order when applying effects to their carrier.
    /// - Throws: ``AxolotyError`` when the effect cannot be applied.
    func perform(_ effect: RuntimeTransportEffect) async throws(AxolotyError)

    /// Stops the transport and releases its callbacks.
    ///
    /// This operation is idempotent. After it returns, the adapter must not
    /// invoke a callback installed by the runtime.
    func stop() async

    /// Activates interest in the profile namespace before identity is advertised.
    ///
    /// Adapters that do not advertise
    /// ``RuntimeTransportCapabilities/profileInterest`` may ignore this call.
    ///
    /// - Parameter namespace: The runtime's immutable Coaty namespace.
    /// - Throws: ``AxolotyError`` when the interest cannot be declared.
    func activateProfileInterest(namespace: String) async throws(AxolotyError)

    /// Deactivates interest in the profile namespace during graceful shutdown.
    ///
    /// Adapters that do not advertise
    /// ``RuntimeTransportCapabilities/profileInterest`` may ignore this call.
    ///
    /// - Parameter namespace: The namespace previously activated.
    /// - Throws: ``AxolotyError`` when the interest cannot be removed.
    func deactivateProfileInterest(namespace: String) async throws(AxolotyError)

    /// Classifies an association route using binding-owned knowledge.
    ///
    /// The borrowed route is valid only for this synchronous call. The
    /// transport must not retain it or impose a profile-wide route grammar.
    /// The default classifies every nonempty route as Coaty traffic. Adapters
    /// that advertise ``RuntimeTransportCapabilities/externalRouteSubscriptions``
    /// must classify their active external routes as
    /// `ProtocolRouteClassification.external`.
    func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification
}

public extension AxolotyRuntimeTransport {
    /// Does nothing for transports that do not report asynchronous recovery.
    ///
    /// - Parameter handler: Recovery callback supplied by the runtime.
    func setRecoveryHandler(_ handler: @escaping @Sendable () -> Void) async { _ = handler }
    /// Does nothing for transports that do not report activity counters.
    ///
    /// - Parameter diagnostics: Runtime-owned counter sink.
    func setDiagnostics(_ diagnostics: RuntimeTransportDiagnostics) async { _ = diagnostics }
    /// Does nothing for transports without separately managed profile interest.
    ///
    /// - Parameter namespace: The runtime's Coaty namespace, unused.
    func activateProfileInterest(namespace: String) async throws(AxolotyError) {}
    /// Does nothing for transports without separately managed profile interest.
    ///
    /// - Parameter namespace: The runtime's Coaty namespace, unused.
    func deactivateProfileInterest(namespace: String) async throws(AxolotyError) {}

    /// Uses the sealed `coaty/3` JSON profile for a binding that does not
    /// override its wire selection.
    var wireProfile: WireProfile { .coaty3JSON }
    /// Classifies every nonempty route as Coaty traffic.
    ///
    /// - Parameter route: A borrowed association route.
    /// - Returns: ``ProtocolRouteClassification/unrelated`` for an empty
    ///   route, otherwise ``ProtocolRouteClassification/coaty``.
    func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification {
        route.length == 0 ? .unrelated : .coaty
    }
}
