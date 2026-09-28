// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyWire
import AxolotyZenohCore
import Foundation

/// The host runtime transport backed by one serialized Zenoh façade session.
///
/// This binding owns publication, subscription lifecycle, and one bounded
/// receive pump for the façade's per-subscription queues.
public final class ZenohBinding: AxolotyRuntimeTransport, @unchecked Sendable {
    // The C façade has one process-wide fixed session registry, so serialize
    // calls across binding instances as well as within each session.
    static let sessionRegistryLock = NSLock()
    let configuration: ZenohBindingConfiguration
    let session: any ZenohBindingSession
    let clock: @Sendable () -> UInt32
    let monotonicNowNanoseconds: @Sendable () -> UInt64
    let routerLossDebounceNanoseconds: UInt64
    let receivePumpIntervalNanoseconds: UInt64
    var started = false
    var stopping = false
    var activeNamespace: String?
    var profileSubscriptions: [Int] = []
    var externalSubscriptions: [ExternalSubscription] = []
    var receive: (@Sendable (RuntimeInboundFrame) -> Void)?
    var failureHandler: (@Sendable (RuntimeTransportFailure) -> Void)?
    var recoveryHandler: (@Sendable () -> Void)?
    var diagnostics: RuntimeTransportDiagnostics?
    var hasOpenedSession = false
    var receivePump: Task<Void, Never>?
    var hasObservedRouter = false
    var routerLossBeganAtNanoseconds: UInt64?
    var routerLossReported = false

    /// A one-second debounce filters short topology changes while remaining
    /// faster than operational retry windows. It is well above the 10 ms poll
    /// interval and within the 0.5–2 s recovery-detection budget.
    static let routerLossDebounceNanoseconds: UInt64 = 1_000_000_000
    static let routerLossFailureDetail = "Zenoh client session lost all connected routers"

    /// Creates a host Zenoh binding.
    ///
    /// - Parameter configuration: Validated bounded connection settings.
    public convenience init(configuration: ZenohBindingConfiguration) {
        self.init(configuration: configuration, session: ZenohFacadeSession())
    }

    /// Creates a binding from settings and maps configuration validation to
    /// the runtime's owned error type.
    ///
    /// - Parameters:
    ///   - connectEndpoint: Zenoh router endpoint.
    ///   - maximumProfileKeyBytes: Maximum profile key length.
    ///   - maximumExternalRoutes: Maximum exact external routes.
    ///   - receiveKeyCapacity: Maximum received key length.
    ///   - receivePayloadCapacity: Maximum received payload length.
    /// - Throws: ``AxolotyError/invalidConfiguration(option:reason:)`` when a
    ///   setting is outside the validated Zenoh bounds.
    public convenience init(
        connectEndpoint: String = "tcp/127.0.0.1:7447",
        maximumProfileKeyBytes: Int = 256,
        maximumExternalRoutes: Int = ZenohBindingConfiguration.maximumExternalRouteCapacity,
        receiveKeyCapacity: Int = ZenohFrameStorage.keyCapacity,
        receivePayloadCapacity: Int = ZenohFrameStorage.payloadCapacity
    ) throws(AxolotyError) {
        let configuration: ZenohBindingConfiguration
        do {
            configuration = try ZenohBindingConfiguration(
                connectEndpoint: connectEndpoint,
                maximumProfileKeyBytes: maximumProfileKeyBytes,
                maximumExternalRoutes: maximumExternalRoutes,
                receiveKeyCapacity: receiveKeyCapacity,
                receivePayloadCapacity: receivePayloadCapacity
            )
        } catch {
            throw ZenohBindingSupport.runtimeError(for: error)
        }
        self.init(configuration: configuration)
    }

    init(
        configuration: ZenohBindingConfiguration,
        session: any ZenohBindingSession,
        clock: @escaping @Sendable () -> UInt32 = ZenohBindingSupport.monotonicNowMS,
        receivePumpIntervalNanoseconds: UInt64 = ZenohBindingSupport.receivePumpIntervalNanoseconds,
        monotonicNowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        routerLossDebounceNanoseconds: UInt64 = ZenohBinding.routerLossDebounceNanoseconds
    ) {
        self.configuration = configuration
        self.session = session
        self.clock = clock
        self.receivePumpIntervalNanoseconds = receivePumpIntervalNanoseconds
        self.monotonicNowNanoseconds = monotonicNowNanoseconds
        self.routerLossDebounceNanoseconds = routerLossDebounceNanoseconds
    }

    /// Opens the Zenoh session and starts its bounded receive pump.
    ///
    /// - Note: The `lastWill` overload intentionally ignores its last-will
    ///   argument because Zenoh's v1 client profile has no broker last-will.
    ///
    /// - Parameter receive: Callback for copied inbound frames.
    /// - Throws: ``AxolotyError`` when the binding is already started or the
    ///   Zenoh session cannot open.
    public func start(
        receive: @escaping @Sendable (RuntimeInboundFrame) -> Void
    ) async throws(AxolotyError) {
        try startLocked(receive: receive)
    }

    /// Starts the binding and ignores the MQTT-compatible last-will value.
    ///
    /// Zenoh's v1 client profile has no broker last-will. The value is accepted
    /// to satisfy the runtime transport port and is intentionally unused.
    ///
    /// - Parameters:
    ///   - receive: Callback for copied inbound frames.
    ///   - lastWill: A runtime last-will value unsupported by Zenoh.
    /// - Throws: ``AxolotyError`` when the Zenoh session cannot start.
    public func start(
        receive: @escaping @Sendable (RuntimeInboundFrame) -> Void,
        lastWill: RuntimeTransportLastWill?
    ) async throws(AxolotyError) {
        _ = lastWill
        try await start(receive: receive)
    }

    /// Stores the callback for failures reported by the receive pump.
    ///
    /// - Parameter handler: The runtime's transport-failure callback.
    public func setFailureHandler(
        _ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void
    ) async {
        Self.sessionRegistryLock.withLock { failureHandler = handler }
    }

    /// Stores the callback invoked once when a reported router outage recovers.
    ///
    /// - Parameter handler: The runtime's soft-recovery callback.
    public func setRecoveryHandler(_ handler: @escaping @Sendable () -> Void) async {
        Self.sessionRegistryLock.withLock { recoveryHandler = handler }
    }

    /// Stores the runtime-owned transport counter sink.
    ///
    /// - Parameter diagnostics: Shared fixed-size counter sink.
    public func setDiagnostics(_ diagnostics: RuntimeTransportDiagnostics) async {
        Self.sessionRegistryLock.withLock { self.diagnostics = diagnostics }
    }

    /// Applies one resolved publication or exact external-route transition.
    ///
    /// - Parameter effect: A finished runtime transport effect.
    /// - Throws: ``AxolotyError`` when the binding is stopped or Zenoh rejects
    ///   the operation.
    public func perform(_ effect: RuntimeTransportEffect) async throws(AxolotyError) {
        try performLocked(effect)
    }

    /// Stops and joins the receive pump, then closes the session and releases
    /// subscription and callback state.
    ///
    /// A close error during an intentional stop is ignored. Shutdown must not
    /// report a transport failure that could request reconnect handling.
    public func stop() async {
        let pump = Self.sessionRegistryLock.withLock { () -> Task<Void, Never>? in
            guard started else { return nil }
            started = false
            stopping = true
            let pump = receivePump
            receivePump = nil
            return pump
        }
        guard let pump else { return }
        pump.cancel()
        await pump.value
        Self.sessionRegistryLock.withLock {
            activeNamespace = nil
            profileSubscriptions.removeAll(keepingCapacity: true)
            externalSubscriptions.removeAll(keepingCapacity: true)
            diagnostics?.setActiveExternalSubscriptions(0)
            receive = nil
            hasObservedRouter = false
            routerLossBeganAtNanoseconds = nil
            routerLossReported = false
            _ = session.close()
            stopping = false
        }
    }

    /// Declares the two bounded Coaty profile-interest key expressions.
    ///
    /// The active namespace cannot be changed in place. If a prior activation
    /// left retained handles after rollback failed, first deactivate that same
    /// namespace; a repeated activation with incomplete retained state fails
    /// rather than silently duplicating or losing subscriptions.
    ///
    /// - Parameter namespace: The runtime's immutable Coaty namespace.
    /// - Throws: ``AxolotyError`` when the binding is stopped, a different
    ///   namespace is active, retained state is incomplete, or Zenoh rejects a
    ///   declaration.
    public func activateProfileInterest(namespace: String) async throws(AxolotyError) {
        try activateProfileInterestLocked(namespace: namespace)
    }

    /// Removes exactly the two profile-interest subscriptions for `namespace`.
    ///
    /// Deactivation is a no-op when the binding is stopped. Runtime shutdown
    /// may reach this method after transport startup failed. The runtime's
    /// reconnect ordering deactivates while started, then stops and starts the
    /// binding before reactivating its immutable namespace.
    ///
    /// - Parameter namespace: The namespace passed to
    ///   ``activateProfileInterest(namespace:)``.
    ///   A different namespace is a no-op.
    /// - Throws: ``AxolotyError`` when Zenoh rejects an undeclaration.
    public func deactivateProfileInterest(namespace: String) async throws(AxolotyError) {
        try deactivateProfileInterestLocked(namespace: namespace)
    }

    /// Forwards one owned transport failure to the runtime callback.
    ///
    /// The receive pump uses this seam for asynchronous façade failures.
    func reportFailure(_ failure: RuntimeTransportFailure) {
        let handler = Self.sessionRegistryLock.withLock { () -> (@Sendable (RuntimeTransportFailure) -> Void)? in
            guard started && !stopping else { return nil }
            diagnostics?.recordSessionFailure()
            return failureHandler
        }
        handler?(failure)
    }

    func reportRecovery() {
        let handler = Self.sessionRegistryLock.withLock { started && !stopping ? recoveryHandler : nil }
        handler?()
    }

    private func activateExternalRoute(_ route: [UInt8]) throws(AxolotyError) {
        guard !route.contains(0x2A) else {
            throw AxolotyError.invalidArgument(
                argument: "route",
                reason: "must be an exact Zenoh key expression without wildcards"
            )
        }
        if let index = externalSubscriptions.firstIndex(where: { $0.route == route }) {
            externalSubscriptions[index].referenceCount += 1
            return
        }
        guard externalSubscriptions.count < configuration.maximumExternalRoutes else {
            throw AxolotyError.runtime(code: .capacityExceeded, reason: "Zenoh external-route table is full")
        }
        let subscription = try session.subscribe(route: route)
        externalSubscriptions.append(ExternalSubscription(
            route: route,
            subscription: subscription,
            referenceCount: 1
        ))
        diagnostics?.setActiveExternalSubscriptions(UInt64(externalSubscriptions.count))
    }

    private func deactivateExternalRoute(_ route: [UInt8]) throws(AxolotyError) {
        guard let index = externalSubscriptions.firstIndex(where: { $0.route == route }) else { return }
        if externalSubscriptions[index].referenceCount > 1 {
            externalSubscriptions[index].referenceCount -= 1
            return
        }
        let result = session.unsubscribe(externalSubscriptions[index].subscription)
        try ZenohBindingSupport.requireSuccess(result, operation: "Zenoh external-route unsubscription")
        externalSubscriptions.remove(at: index)
        diagnostics?.setActiveExternalSubscriptions(UInt64(externalSubscriptions.count))
    }

    private func startLocked(
        receive: @escaping @Sendable (RuntimeInboundFrame) -> Void
    ) throws(AxolotyError) {
        Self.sessionRegistryLock.lock()
        defer { Self.sessionRegistryLock.unlock() }
        guard !started, !stopping else {
            throw AxolotyError.runtime(code: .notStarted, reason: "Zenoh binding is already started")
        }
        let endpoint = Array(configuration.connectEndpoint.utf8)
        do {
            try ZenohBindingSupport.requireSuccess(session.open(endpoint: endpoint), operation: "Zenoh session open")
        } catch {
            diagnostics?.recordSessionFailure()
            throw error
        }
        if hasOpenedSession { diagnostics?.recordReconnect() }
        hasOpenedSession = true
        diagnostics?.recordSessionOpen()
        hasObservedRouter = false
        routerLossBeganAtNanoseconds = nil
        routerLossReported = false
        self.receive = receive
        started = true
        startReceivePumpLocked()
    }

    private func performLocked(_ effect: RuntimeTransportEffect) throws(AxolotyError) {
        Self.sessionRegistryLock.lock()
        defer { Self.sessionRegistryLock.unlock() }
        guard started else {
            throw AxolotyError.runtime(code: .notStarted, reason: "Zenoh binding is not started")
        }
        switch effect {
        case let .publish(message):
            try ZenohBindingSupport.requireSuccess(
                session.publish(route: Array(message.route.utf8), payload: Array(message.payload)),
                operation: "Zenoh publication"
            )
            diagnostics?.recordPublishedFrame()
        case let .externalRouteActivated(transition):
            try activateExternalRoute(transition.route)
        case let .externalRouteDeactivated(transition):
            try deactivateExternalRoute(transition.route)
        }
    }

    private func activateProfileInterestLocked(namespace: String) throws(AxolotyError) {
        Self.sessionRegistryLock.lock()
        defer { Self.sessionRegistryLock.unlock() }
        guard started else {
            throw AxolotyError.runtime(code: .notStarted, reason: "Zenoh binding is not started")
        }
        if activeNamespace == namespace {
            guard profileSubscriptions.count == 2 else {
                throw AxolotyError.runtime(
                    code: .subscriptionFailed,
                    reason: "Zenoh profile interest has incomplete subscription state"
                )
            }
            return
        }
        guard activeNamespace == nil else {
            throw AxolotyError.invalidConfiguration(
                option: "namespace",
                reason: "Zenoh profile interest is already active for another namespace"
            )
        }
        try ZenohBindingSupport.validateNamespace(namespace)

        let installed = try installProfileSubscriptions(namespace: namespace)
        profileSubscriptions = installed
        activeNamespace = namespace
    }

    private func installProfileSubscriptions(namespace: String) throws(AxolotyError) -> [Int] {
        var installed: [Int] = []
        for route in ZenohBindingSupport.profileInterestRoutes(namespace: namespace) {
            do {
                installed.append(try session.subscribe(route: Array(route.utf8)))
            } catch {
                var rollbackError: AxolotyError?
                var remaining: [Int] = []
                for subscription in installed {
                    let result = session.unsubscribe(subscription)
                    if result != .success {
                        remaining.append(subscription)
                        if rollbackError == nil {
                            rollbackError = ZenohBindingSupport.error(
                                for: result,
                                operation: "Zenoh profile subscription rollback"
                            )
                        }
                    }
                }
                if let rollbackError {
                    profileSubscriptions = remaining
                    activeNamespace = remaining.isEmpty ? nil : namespace
                    throw AxolotyError.runtime(
                        code: .subscriptionFailed,
                        reason: "Profile subscription failed: \(error.userFriendlyMessage); " +
                            "rollback failed: \(rollbackError.userFriendlyMessage)"
                    )
                }
                throw error
            }
        }
        return installed
    }

    private func deactivateProfileInterestLocked(namespace: String) throws(AxolotyError) {
        Self.sessionRegistryLock.lock()
        defer { Self.sessionRegistryLock.unlock() }
        guard started else { return }
        guard activeNamespace == namespace else { return }

        var firstError: AxolotyError?
        var remaining: [Int] = []
        for subscription in profileSubscriptions {
            let result = session.unsubscribe(subscription)
            if result == .success { continue }
            if firstError == nil {
                firstError = ZenohBindingSupport.error(
                    for: result,
                    operation: "Zenoh profile unsubscription"
                )
            }
            remaining.append(subscription)
        }
        profileSubscriptions = remaining
        if remaining.isEmpty { activeNamespace = nil }
        if let firstError { throw firstError }
    }

}
