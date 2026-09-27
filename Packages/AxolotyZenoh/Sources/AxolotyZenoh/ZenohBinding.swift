// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyWire
import AxolotyZenohCore
import Foundation

/// The host runtime transport backed by one serialized Zenoh façade session.
///
/// This binding owns publication and subscription lifecycle. The receive pump
/// is intentionally separate; it will poll the per-subscription queues in the
/// follow-up host receive workstream.
public final class ZenohBinding: AxolotyRuntimeTransport, @unchecked Sendable {
    // The C façade has one process-wide fixed session registry, so serialize
    // calls across binding instances as well as within each session.
    private static let sessionRegistryLock = NSLock()
    private let configuration: ZenohBindingConfiguration
    private let session: any ZenohBindingSession
    private var started = false
    private var activeNamespace: String?
    private var profileSubscriptions: [Int] = []
    private var externalSubscriptions: [ExternalSubscription] = []
    private var receive: (@Sendable (RuntimeInboundFrame) -> Void)?
    private var failureHandler: (@Sendable (RuntimeTransportFailure) -> Void)?

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
    ///   - receiveQueueCapacity: Maximum queued frames per subscription.
    ///   - receiveKeyCapacity: Maximum received key length.
    ///   - receivePayloadCapacity: Maximum received payload length.
    /// - Throws: ``AxolotyError/invalidConfiguration(option:reason:)`` when a
    ///   setting is outside the validated Zenoh bounds.
    public convenience init(
        connectEndpoint: String = "tcp/127.0.0.1:7447",
        maximumProfileKeyBytes: Int = 256,
        maximumExternalRoutes: Int = ZenohBindingConfiguration.maximumExternalRouteCapacity,
        receiveQueueCapacity: Int = 4,
        receiveKeyCapacity: Int = ZenohFrameStorage.keyCapacity,
        receivePayloadCapacity: Int = ZenohFrameStorage.payloadCapacity
    ) throws(AxolotyError) {
        let configuration: ZenohBindingConfiguration
        do {
            configuration = try ZenohBindingConfiguration(
                connectEndpoint: connectEndpoint,
                maximumProfileKeyBytes: maximumProfileKeyBytes,
                maximumExternalRoutes: maximumExternalRoutes,
                receiveQueueCapacity: receiveQueueCapacity,
                receiveKeyCapacity: receiveKeyCapacity,
                receivePayloadCapacity: receivePayloadCapacity
            )
        } catch {
            throw ZenohBindingSupport.runtimeError(for: error)
        }
        self.init(configuration: configuration)
    }

    init(configuration: ZenohBindingConfiguration, session: any ZenohBindingSession) {
        self.configuration = configuration
        self.session = session
    }

    /// Opens the Zenoh session and retains the copied-frame callback for the
    /// receive pump added by the host receive workstream.
    ///
    /// - Note: The `lastWill` overload intentionally ignores its last-will
    ///   argument because Zenoh's v1 client profile has no broker last-will.
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
    public func setFailureHandler(
        _ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void
    ) async {
        Self.sessionRegistryLock.withLock { failureHandler = handler }
    }

    /// Applies one resolved publication or exact external-route transition.
    ///
    /// - Parameter effect: A finished runtime transport effect.
    /// - Throws: ``AxolotyError`` when the binding is stopped or Zenoh rejects
    ///   the operation.
    public func perform(_ effect: RuntimeTransportEffect) async throws(AxolotyError) {
        try performLocked(effect)
    }

    /// Closes the session and releases subscription and callback state.
    ///
    /// A close error during an intentional stop is ignored. Shutdown must not
    /// report a transport failure that could request reconnect handling.
    public func stop() async {
        Self.sessionRegistryLock.withLock {
            guard started else { return }
            started = false
            activeNamespace = nil
            profileSubscriptions.removeAll(keepingCapacity: true)
            externalSubscriptions.removeAll(keepingCapacity: true)
            receive = nil
            _ = session.close()
        }
    }

    /// Declares the two bounded Coaty profile-interest key expressions.
    public func activateProfileInterest(namespace: String) async throws(AxolotyError) {
        try activateProfileInterestLocked(namespace: namespace)
    }

    /// Removes exactly the two profile-interest subscriptions for `namespace`.
    public func deactivateProfileInterest(namespace: String) async throws(AxolotyError) {
        try deactivateProfileInterestLocked(namespace: namespace)
    }

    /// Classifies a route using the active namespace and binding bounds.
    ///
    /// - Parameter route: A borrowed route valid only for this call.
    /// - Returns: `.coaty`, `.external`, or `.unrelated` for this binding.
    public func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification {
        let namespace = Self.sessionRegistryLock.withLock { activeNamespace }
        return ZenohBindingSupport.classify(
            route,
            activeNamespace: namespace,
            maximumProfileKeyLength: configuration.maximumProfileKeyBytes
        )
    }

    /// Forwards one owned transport failure to the runtime callback.
    ///
    /// The receive pump uses this seam for asynchronous façade failures.
    func reportFailure(_ failure: RuntimeTransportFailure) {
        let handler = Self.sessionRegistryLock.withLock { failureHandler }
        handler?(failure)
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
    }

    private func startLocked(
        receive: @escaping @Sendable (RuntimeInboundFrame) -> Void
    ) throws(AxolotyError) {
        Self.sessionRegistryLock.lock()
        defer { Self.sessionRegistryLock.unlock() }
        guard !started else {
            throw AxolotyError.runtime(code: .notStarted, reason: "Zenoh binding is already started")
        }
        let endpoint = Array(configuration.connectEndpoint.utf8)
        try ZenohBindingSupport.requireSuccess(session.open(endpoint: endpoint), operation: "Zenoh session open")
        self.receive = receive
        started = true
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
        guard started else {
            throw AxolotyError.runtime(code: .notStarted, reason: "Zenoh binding is not started")
        }
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
