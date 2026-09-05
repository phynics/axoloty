// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyProtocol
import AxolotyWire
import Foundation
import NIOConcurrencyHelpers

/// Host MQTT connection settings for ``MQTTBinding``.
public struct MQTTBindingConfiguration: Sendable, Equatable {
    /// Broker host name or address.
    public let host: String
    /// Broker TCP port.
    public let port: UInt16
    /// Enables TLS in the underlying MQTT client.
    public let usesTLS: Bool
    /// Optional broker credentials.
    public let username: String?
    /// Optional broker password.
    public let password: String?
    /// Maximum time to wait for the broker to report an online state.
    public let connectionTimeoutMS: UInt32
    /// Maximum time to wait for a broker acknowledgement (SUBACK, UNSUBACK,
    /// PUBACK) before failing the operation.
    ///
    /// Without this bound the underlying client waits for an acknowledgement
    /// forever. A broker that disappears without resetting the connection --
    /// a restarted broker whose socket is left half-open -- then wedges any
    /// operation awaiting an acknowledgement, including the
    /// `removeSubscriptions(namespace:)` that opens a reconnect. That hang is
    /// unrecoverable: no reconnect can run while it is pending.
    ///
    /// - Note: MQTTNIO applies one timeout to every acknowledged exchange, so
    ///   this also bounds the keepalive `PINGRESP`. A broker that fails to
    ///   answer a ping within this window is treated as a transport failure and
    ///   the runtime enters `.reconnecting`, which it recovers from by
    ///   retrying. The trade is deliberate: an unbounded wait is an
    ///   unrecoverable hang, while a premature ping timeout costs one
    ///   recoverable reconnect.
    public let operationTimeoutMS: UInt32
    /// Largest Coaty profile topic admitted before runtime validation.
    public let maximumProfileTopicBytes: Int
    /// Maximum exact external compatibility routes the binding will track
    /// and subscribe to simultaneously.
    public let maximumExternalRoutes: Int

    /// Creates a bounded MQTT binding configuration.
    ///
    /// - Parameters:
    ///   - host: Broker host name or address.
    ///   - port: Broker TCP port.
    ///   - usesTLS: Enables TLS in the underlying MQTT client.
    ///   - username: Optional broker credentials.
    ///   - password: Optional broker password.
    ///   - connectionTimeoutMS: Maximum time to wait for the broker to
    ///     report an online state. Must be in `1...120000`.
    ///   - operationTimeoutMS: Maximum time to wait for a broker
    ///     acknowledgement before failing the operation. Must be in
    ///     `1...120000`.
    ///   - maximumProfileTopicBytes: Largest Coaty profile topic admitted
    ///     before runtime validation. Must be in `1...65536`.
    ///   - maximumExternalRoutes: Maximum exact external compatibility
    ///     routes tracked simultaneously. Must be in `1...64`.
    /// - Throws: ``AxolotyError/invalidArgument(argument:reason:)`` when any
    ///   parameter is outside its bounds.
    public init(
        host: String = "localhost",
        port: UInt16 = 1883,
        usesTLS: Bool = false,
        username: String? = nil,
        password: String? = nil,
        connectionTimeoutMS: UInt32 = 10_000,
        operationTimeoutMS: UInt32 = 10_000,
        maximumProfileTopicBytes: Int = 512,
        maximumExternalRoutes: Int = 64
    ) throws {
        guard !host.isEmpty, port > 0 else {
            throw AxolotyError.invalidArgument(argument: "broker", reason: "host and port are required")
        }
        guard connectionTimeoutMS > 0, connectionTimeoutMS <= 120_000 else {
            throw AxolotyError.invalidArgument(
                argument: "connectionTimeoutMS",
                reason: "must be in 1...120000"
            )
        }
        guard operationTimeoutMS > 0, operationTimeoutMS <= 120_000 else {
            throw AxolotyError.invalidArgument(
                argument: "operationTimeoutMS",
                reason: "must be in 1...120000"
            )
        }
        guard maximumProfileTopicBytes > 0, maximumProfileTopicBytes <= 65_536 else {
            throw AxolotyError.invalidArgument(
                argument: "maximumProfileTopicBytes",
                reason: "must be in 1...65536"
            )
        }
        guard maximumExternalRoutes > 0, maximumExternalRoutes <= 64 else {
            throw AxolotyError.invalidArgument(
                argument: "maximumExternalRoutes",
                reason: "must be in 1...64"
            )
        }
        self.host = host
        self.port = port
        self.usesTLS = usesTLS
        self.username = username
        self.password = password
        self.connectionTimeoutMS = connectionTimeoutMS
        self.operationTimeoutMS = operationTimeoutMS
        self.maximumProfileTopicBytes = maximumProfileTopicBytes
        self.maximumExternalRoutes = maximumExternalRoutes
    }
}

/// MQTT transport binding used by the structured host runtime.
///
/// The binding owns only transport concerns. It copies every callback payload
/// before handing it to ``AxolotyRuntime`` and never parses protocol families.
public final class MQTTBinding: AxolotyRuntimeTransport, @unchecked Sendable {
    private let lock = NIOLock()
    private let client: RuntimeMQTTClient
    private let delegate: RuntimeMQTTDelegate
    private let connectionTimeoutMS: UInt32
    private let maximumProfileTopicBytes: Int
    private let maximumExternalRoutes: Int
    private var started = false
    private var activeNamespace: String?
    private var transportEpoch: UInt64 = 0
    private var externalRoutes: [ExternalRouteRecord] = []

    /// Creates a binding backed by the repository's MQTTNIO implementation.
    public init(configuration: MQTTBindingConfiguration) throws {
        let delegate = RuntimeMQTTDelegate()
        self.delegate = delegate
        self.connectionTimeoutMS = configuration.connectionTimeoutMS
        self.maximumProfileTopicBytes = configuration.maximumProfileTopicBytes
        self.maximumExternalRoutes = configuration.maximumExternalRoutes
        self.client = try RuntimeMQTTClient(configuration: configuration, delegate: delegate)
    }

    /// Starts the broker connection and installs the copied frame callback.
    public func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let admitted = lock.withLock {
                    guard !started else { return false }
                    started = true
                    transportEpoch &+= 1
                    activeNamespace = nil
                    externalRoutes.removeAll(keepingCapacity: true)
                    return true
                }
                guard admitted else {
                    continuation.resume(throwing: AxolotyError.runtime(code: .notStarted, reason: "MQTT binding is already started"))
                    return
                }
                delegate.setReceive { [weak self] topic, payload, nowMS in
                    self?.admitInbound(topic: topic, payload: payload, nowMS: nowMS, receive: receive)
                }
                delegate.setStartContinuation(continuation)
                delegate.armStartTimeout(milliseconds: connectionTimeoutMS)
                client.connect()
            }
        } catch {
            lock.withLock {
                started = false
                transportEpoch &+= 1
                activeNamespace = nil
                externalRoutes.removeAll(keepingCapacity: true)
            }
            await client.disconnect()
            delegate.clearReceive()
            throw error
        }
    }

    /// Forwards post-start transport failures to the owning runtime.
    public func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async {
        delegate.setFailureHandler(handler)
    }

    /// Applies one transport effect in the order produced by the protocol.
    ///
    /// - Parameter effect: A finished publication, or an exact external-route
    ///   lifecycle effect. The route arrives resolved.
    /// - Throws: A transport error when the effect cannot be applied.
    public func perform(_ effect: RuntimeTransportEffect) async throws {
        guard lock.withLock({ started }) else {
            throw AxolotyError.runtime(code: .notStarted, reason: "MQTT binding is not started")
        }
        switch effect {
        case .publish(let message):
            do {
                try await client.publish(topic: message.route, payload: message.payload)
            } catch {
                throw AxolotyError.network(error: error, reason: "MQTT publication failed")
            }
        case .externalRouteActivated(let transition):
            try await activateExternalRoute(transition.route)
        case .externalRouteDeactivated(let transition):
            try await deactivateExternalRoute(transition.route)
        }
    }

    /// Stops the MQTT connection and releases callback admission.
    public func stop() async {
        lock.withLock {
            started = false
            transportEpoch &+= 1
            activeNamespace = nil
            externalRoutes.removeAll(keepingCapacity: true)
        }
        delegate.failStart(AxolotyError.runtime(code: .cancelled, reason: "MQTT binding stopped while connecting"))
        await client.disconnect()
        delegate.clearReceive()
    }

    /// Installs bounded wildcard subscriptions for the closed profile.
    public func installSubscriptions(namespace: String) async throws {
        lock.withLock { activeNamespace = namespace }
        try await client.subscribe(RuntimeTopicBuilder.subscribeAllOneWayTopics(namespace: namespace))
        // Request/reply filters (for example `UPD::com.example.Type` and
        // `CLL:operation`) are encoded in the event-type topic segment. MQTT
        // wildcards match complete segments, so a family-specific `UPD/+`-
        // style filter would not match those suffixed event types. The
        // correlated shape has exactly three segments after the namespace;
        // subscribe once to that bounded shape and let ProtocolProcessor
        // enforce the closed capability set.
        try await client.subscribe(RuntimeTopicBuilder.subscribeAllCorrelatedTopics(namespace: namespace))
    }

    /// Removes the same profile subscriptions during shutdown/reconnect.
    public func removeSubscriptions(namespace: String) async throws {
        let routes = lock.withLock { () -> [String] in
            transportEpoch &+= 1
            activeNamespace = nil
            let routes = externalRoutes.map(\.topic)
            externalRoutes.removeAll(keepingCapacity: true)
            return routes
        }
        var firstError: Error?
        for route in routes {
            do { try await client.unsubscribe(route) }
            catch { if firstError == nil { firstError = error } }
        }
        do { try await client.unsubscribe(RuntimeTopicBuilder.subscribeAllOneWayTopics(namespace: namespace)) }
        catch { if firstError == nil { firstError = error } }
        do { try await client.unsubscribe(RuntimeTopicBuilder.subscribeAllCorrelatedTopics(namespace: namespace)) }
        catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }

    /// Classifies the binding's exact external compatibility route.
    public func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification {
        let namespace = lock.withLock { activeNamespace }
        return Self.classify(
            route,
            activeNamespace: namespace,
            maximumProfileTopicLength: maximumProfileTopicBytes
        )
    }

    /// Determines what ``activateExternalRoute(_:)`` must do for one exact
    /// external route, given the current table and configured bound.
    ///
    /// This is a pure decision step (no locking, no I/O) so the caller's
    /// error attribution can be exercised directly by tests: the returned
    /// failure always names the one condition that was actually observed --
    /// the binding not being started, an existing record mid-transition, or
    /// the table being genuinely at capacity -- rather than a cause inferred
    /// after the fact from unrelated state.
    ///
    /// - Parameters:
    ///   - topic: The exact route topic being activated.
    ///   - started: Whether the owning binding is currently started.
    ///   - routes: The external route table, mutated in place on success.
    ///   - capacity: The configured maximum number of tracked routes.
    ///   - transportEpoch: The binding's current transport epoch, stamped
    ///     onto any newly created record.
    /// - Returns: `.success` with the record epoch and whether a new broker
    ///   subscription must be issued, or `.failure` with the ``AxolotyError``
    ///   that reports the exact cause.
    static func resolveExternalRouteActivation(
        topic: String,
        started: Bool,
        routes: inout [ExternalRouteRecord],
        capacity: Int,
        transportEpoch: UInt64
    ) -> Result<(epoch: UInt64, shouldSubscribe: Bool), AxolotyError> {
        guard started else {
            return .failure(AxolotyError.runtime(code: .notStarted, reason: "MQTT binding is not started"))
        }
        if let index = routes.firstIndex(where: { $0.topic == topic }) {
            guard routes[index].state == .subscribed else {
                return .failure(AxolotyError.runtime(
                    code: .subscriptionFailed,
                    reason: "MQTT external route is transitioning and cannot be activated"
                ))
            }
            routes[index].referenceCount += 1
            return .success((routes[index].epoch, false))
        }
        guard routes.count < capacity else {
            return .failure(AxolotyError.runtime(code: .capacityExceeded, reason: "MQTT external route table is full"))
        }
        let epoch = transportEpoch
        routes.append(ExternalRouteRecord(
            topic: topic,
            referenceCount: 1,
            state: .subscribing,
            epoch: epoch
        ))
        return .success((epoch, true))
    }

    private func activateExternalRoute(_ route: [UInt8]) async throws {
        let topic = String(decoding: route, as: UTF8.self)
        let action: Result<(epoch: UInt64, shouldSubscribe: Bool), AxolotyError> = lock.withLock {
            Self.resolveExternalRouteActivation(
                topic: topic,
                started: started,
                routes: &externalRoutes,
                capacity: maximumExternalRoutes,
                transportEpoch: transportEpoch
            )
        }
        let resolved = try action.get()
        guard resolved.shouldSubscribe else { return }
        do {
            try await client.subscribe(topic)
            lock.withLock {
                guard resolved.epoch == transportEpoch,
                      let index = externalRoutes.firstIndex(where: { $0.topic == topic && $0.epoch == resolved.epoch }) else { return }
                externalRoutes[index].state = .subscribed
            }
        } catch {
            lock.withLock {
                externalRoutes.removeAll { $0.topic == topic && $0.epoch == resolved.epoch }
            }
            throw AxolotyError.network(error: error, reason: "MQTT external route subscription failed")
        }
    }

    private func deactivateExternalRoute(_ route: [UInt8]) async throws {
        let topic = String(decoding: route, as: UTF8.self)
        let action = lock.withLock { () -> (epoch: UInt64, shouldUnsubscribe: Bool)? in
            guard let index = externalRoutes.firstIndex(where: { $0.topic == topic }) else { return nil }
            guard externalRoutes[index].state == .subscribed else { return nil }
            if externalRoutes[index].referenceCount > 1 {
                externalRoutes[index].referenceCount -= 1
                return (externalRoutes[index].epoch, false)
            }
            externalRoutes[index].state = .unsubscribing
            return (externalRoutes[index].epoch, true)
        }
        guard let action, action.shouldUnsubscribe else { return }
        do {
            try await client.unsubscribe(topic)
            lock.withLock {
                guard action.epoch == transportEpoch else { return }
                externalRoutes.removeAll { $0.topic == topic && $0.epoch == action.epoch }
            }
        } catch {
            lock.withLock {
                guard action.epoch == transportEpoch,
                      let index = externalRoutes.firstIndex(where: { $0.topic == topic && $0.epoch == action.epoch }) else { return }
                externalRoutes[index].state = .subscribed
                externalRoutes[index].referenceCount = 1
            }
            throw AxolotyError.network(error: error, reason: "MQTT external route unsubscription failed")
        }
    }

    private func admitInbound(
        topic: String,
        payload: [UInt8],
        nowMS: UInt32,
        receive: @escaping @Sendable (RuntimeInboundFrame) -> Void
    ) {
        let frame = lock.withLock { () -> RuntimeInboundFrame? in
            guard started else { return nil }
            let bytes = Array(topic.utf8)
            if Self.isActiveProfile(
                bytes,
                namespace: activeNamespace,
                maximumTopicLength: maximumProfileTopicBytes
            ) {
                return .profile(route: topic, payload: payload, nowMS: nowMS)
            }
            guard externalRoutes.contains(where: {
                $0.state == .subscribed && $0.epoch == transportEpoch && $0.topic == topic
            }) else { return nil }
            return .externalIo(route: topic, payload: payload, nowMS: nowMS)
        }
        if let frame { receive(frame) }
    }

    private static func isActiveProfile(
        _ bytes: [UInt8],
        namespace: String?,
        maximumTopicLength: Int
    ) -> Bool {
        guard let namespace else { return false }
        return bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            let view = TopicView(topicBytes: base, length: buffer.count)
            guard (try? view.validate(maximumTopicLength: maximumTopicLength)) != nil,
                  let actualNamespace = view.namespaceLevel else { return false }
            return actualNamespace.utf8Equals(namespace)
        }
    }

    private static func classify(
        _ route: ByteSlice,
        activeNamespace: String?,
        maximumProfileTopicLength: Int
    ) -> ProtocolRouteClassification {
        guard route.length > 0 else { return .unrelated }
        for index in 0..<route.length {
            guard let byte = route.byte(at: index), byte != 0, byte != 0x23, byte != 0x2B else { return .unrelated }
            if byte == 0x2F {
                guard index > 0, route.byte(at: index - 1) != 0x2F,
                      index + 1 < route.length, route.byte(at: index + 1) != 0x2F else { return .unrelated }
            }
        }
        var bytes = [UInt8](repeating: 0, count: route.length)
        for index in 0..<route.length { bytes[index] = route.byte(at: index)! }
        return bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return .unrelated }
            let view = TopicView(topicBytes: base, length: buffer.count)
            let coatyPrefix = Array("coaty/3/".utf8)
            let startsWithCoatyProfile = bytes.starts(with: coatyPrefix)
            if startsWithCoatyProfile {
                guard (try? view.validate(maximumTopicLength: maximumProfileTopicLength)) != nil,
                      let namespace = activeNamespace,
                      view.namespaceLevel?.utf8Equals(namespace) == true else {
                    return .unrelated
                }
                guard let eventType = view.eventType else { return .unrelated }
                return Self.staticStringEquals(eventType.wireCode, "IOV") ? .coaty : .unrelated
            }
            guard route.length <= WireBufferConfig.maxTopicLength else { return .unrelated }
            return .external
        }
    }

    private static func staticStringEquals(_ value: StaticString, _ literal: StaticString) -> Bool {
        guard value.utf8CodeUnitCount == literal.utf8CodeUnitCount else { return false }
        for index in 0..<value.utf8CodeUnitCount where value.utf8Start[index] != literal.utf8Start[index] {
            return false
        }
        return true
    }
}

enum ExternalRouteSubscriptionState: Sendable, Equatable {
    case subscribing, subscribed, unsubscribing
}

struct ExternalRouteRecord: Sendable, Equatable {
    let topic: String
    var referenceCount: Int
    var state: ExternalRouteSubscriptionState
    let epoch: UInt64
}

private final class RuntimeMQTTDelegate: RuntimeMQTTClientDelegate, @unchecked Sendable {
    private let lock = NIOLock()
    private var receive: (@Sendable (String, [UInt8], UInt32) -> Void)?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startTimeoutTask: Task<Void, Never>?

    func setReceive(_ receive: @escaping @Sendable (String, [UInt8], UInt32) -> Void) {
        lock.withLock { self.receive = receive }
    }

    func clearReceive() {
        lock.withLock { receive = nil }
    }

    func setStartContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { startContinuation = continuation }
    }

    func armStartTimeout(milliseconds: UInt32) {
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(Int64(milliseconds)))
                self?.failStart(AxolotyError.runtime(
                    code: .brokerUnavailable,
                    reason: "MQTT broker did not become online before the connection deadline"
                ))
            } catch {
                // Completion cancels the timer; cancellation is expected.
            }
        }
        lock.withLock {
            startTimeoutTask?.cancel()
            startTimeoutTask = timeoutTask
        }
    }

    func runtimeMQTTClientDidBecomeOnline() {
        finishStart(.success(()))
    }

    func runtimeMQTTClientDidBecomeOffline() {
        let error = AxolotyError.runtime(
            code: .brokerUnavailable,
            reason: "MQTT broker connection failed before the runtime became online"
        )
        if !finishStart(.failure(error)) { emitFailure(error) }
    }

    func runtimeMQTTClientDidFail(_ error: Error) {
        if !finishStart(.failure(error)) { emitFailure(error) }
    }

    func failStart(_ error: Error) {
        finishStart(.failure(error))
    }

    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        lock.withLock { failure = handler }
    }

    private var failure: (@Sendable (Error) -> Void)?

    private func emitFailure(_ error: Error) {
        let callback = lock.withLock { failure }
        callback?(error)
    }

    @discardableResult
    private func finishStart(_ result: Result<Void, Error>) -> Bool {
        let (continuation, timeoutTask): (CheckedContinuation<Void, Error>?, Task<Void, Never>?) = lock.withLock {
            let continuation = startContinuation
            let timeoutTask = startTimeoutTask
            startContinuation = nil
            startTimeoutTask = nil
            return (continuation, timeoutTask)
        }
        timeoutTask?.cancel()
        guard let continuation else { return false }
        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
        return true
    }

    func runtimeMQTTClientDidReceive(topic: String, payload: [UInt8]) {
        let callback = lock.withLock { receive }
        callback?(
            topic,
            payload,
            UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
        )
    }
}

private enum RuntimeTopicBuilder {
    static func subscribeAllOneWayTopics(namespace: String) -> String {
        "coaty/3/\(namespace)/+/+"
    }

    static func subscribeAllCorrelatedTopics(namespace: String) -> String {
        "coaty/3/\(namespace)/+/+/+"
    }
}
