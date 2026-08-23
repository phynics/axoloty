// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

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

    /// Creates a bounded MQTT binding configuration.
    public init(
        host: String = "localhost",
        port: UInt16 = 1883,
        usesTLS: Bool = false,
        username: String? = nil,
        password: String? = nil,
        connectionTimeoutMS: UInt32 = 10_000
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
        self.host = host
        self.port = port
        self.usesTLS = usesTLS
        self.username = username
        self.password = password
        self.connectionTimeoutMS = connectionTimeoutMS
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
    private let routeClassifier = ExactProtocolRouteClassifier(
        externalRoute: "external/wire-compat-v1/io-external-1"
    )
    private var started = false

    /// Creates a binding backed by the repository's MQTTNIO implementation.
    public init(configuration: MQTTBindingConfiguration) throws {
        let delegate = RuntimeMQTTDelegate()
        self.delegate = delegate
        self.connectionTimeoutMS = configuration.connectionTimeoutMS
        self.client = try RuntimeMQTTClient(configuration: configuration, delegate: delegate)
    }

    /// Starts the broker connection and installs the copied frame callback.
    public func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let admitted = lock.withLock {
                    guard !started else { return false }
                    started = true
                    return true
                }
                guard admitted else {
                    continuation.resume(throwing: AxolotyError.runtime(code: .notStarted, reason: "MQTT binding is already started"))
                    return
                }
                delegate.setReceive(receive)
                delegate.setStartContinuation(continuation)
                delegate.armStartTimeout(milliseconds: connectionTimeoutMS)
                client.connect()
            }
        } catch {
            lock.withLock { started = false }
            await client.disconnect()
            delegate.clearReceive()
            throw error
        }
    }

    /// Forwards post-start transport failures to the owning runtime.
    public func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async {
        delegate.setFailureHandler(handler)
    }

    /// Publishes one normalized action using the canonical Coaty topic shape.
    public func send(_ action: OwnedProtocolAction, namespace: String) async throws {
        guard lock.withLock({ started }) else {
            throw AxolotyError.runtime(code: .notStarted, reason: "MQTT binding is not started")
        }
        let topic = Self.topic(
            for: action.routingKey,
            namespace: namespace,
            eventTypeFilter: action.eventTypeFilter,
            eventTypeFilterKind: action.eventTypeFilterKind
        )
        try await client.publish(topic: topic, payload: action.payload)
    }

    /// Stops the MQTT connection and releases callback admission.
    public func stop() async {
        lock.withLock { started = false }
        delegate.failStart(AxolotyError.runtime(code: .cancelled, reason: "MQTT binding stopped while connecting"))
        await client.disconnect()
        delegate.clearReceive()
    }

    /// Installs bounded wildcard subscriptions for the closed profile.
    public func installSubscriptions(namespace: String) async throws {
        try await client.subscribe(RuntimeTopicBuilder.subscribeAllOneWayTopics(namespace: namespace))
        let responseFamilies: [WireEventType] = [.discover, .resolve, .query, .retrieve, .update, .complete, .call, .returnEvent]
        for family in responseFamilies {
            try await client.subscribe(RuntimeTopicBuilder.subscribeTopic(eventType: family, namespace: namespace))
        }
    }

    /// Removes the same profile subscriptions during shutdown/reconnect.
    public func removeSubscriptions(namespace: String) async throws {
        try await client.unsubscribe(RuntimeTopicBuilder.subscribeAllOneWayTopics(namespace: namespace))
        let responseFamilies: [WireEventType] = [.discover, .resolve, .query, .retrieve, .update, .complete, .call, .returnEvent]
        for family in responseFamilies {
            try await client.unsubscribe(RuntimeTopicBuilder.subscribeTopic(eventType: family, namespace: namespace))
        }
    }

    /// Publishes a minimal modern Identity advertisement before runtime ready.
    public func advertise(identity: RuntimeIdentity?, namespace: String) async throws {
        guard let identity else { return }
        let payload = try Self.identityPayload(identity)
        let key = try ProtocolRoutingKey(capability: .advertise, sourceID: identity.id)
        try await client.publish(
            topic: Self.topic(
                for: key,
                namespace: namespace,
                eventTypeFilter: Array("Identity".utf8)
            ),
            payload: payload
        )
    }

    /// Publishes a matching Deadvertise payload during graceful shutdown.
    public func deadvertise(identity: RuntimeIdentity?, namespace: String) async throws {
        guard let identity else { return }
        let payload = Array("[\"\(Self.uuidString(identity.id))\"]".utf8)
        let key = try ProtocolRoutingKey(capability: .deadvertise, sourceID: identity.id)
        try await client.publish(topic: Self.topic(for: key, namespace: namespace), payload: payload)
    }

    /// Classifies the binding's exact external compatibility route.
    public func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification {
        routeClassifier.classify(route)
    }

    static func topic(
        for key: ProtocolRoutingKey,
        namespace: String,
        eventTypeFilter: [UInt8]? = nil,
        eventTypeFilterKind: ProtocolEventTypeFilterKind = .direct
    ) -> String {
        let separator = eventTypeFilterKind == .objectType ? "::" : ":"
        let filter = eventTypeFilter.map { "\(separator)\(String(bytes: $0, encoding: .utf8) ?? "")" } ?? ""
        var topic = "coaty/3/\(namespace)/\(key.capability.wireEventType.rawValue)\(filter)/\(uuidString(key.sourceID))"
        if let correlationID = key.correlationID {
            topic += "/\(uuidString(correlationID))"
        }
        return topic
    }

    private static func identityPayload(_ identity: RuntimeIdentity) throws -> [UInt8] {
        let object: [String: Any] = [
            "objectId": uuidString(identity.id),
            "coreType": "Identity",
            "objectType": "coaty.Identity",
            "name": identity.name
        ]
        return try JSONSerialization.data(withJSONObject: ["object": object], options: [.sortedKeys]).map { $0 }
    }

    static func uuidString(_ value: UUID16) -> String {
        let bytes = value.bytes
        let raw: [UInt8] = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7, bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15]
        let hex = raw.map { String(format: "%02x", $0) }
        return "\(hex[0...3].joined())-\(hex[4...5].joined())-\(hex[6...7].joined())-\(hex[8...9].joined())-\(hex[10...15].joined())"
    }
}

private final class RuntimeMQTTDelegate: RuntimeMQTTClientDelegate, @unchecked Sendable {
    private let lock = NIOLock()
    private var receive: (@Sendable (RuntimeInboundFrame) -> Void)?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startTimeoutTask: Task<Void, Never>?

    func setReceive(_ receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) {
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
        callback?(RuntimeInboundFrame(
            topic: topic,
            payload: payload,
            nowMS: UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
        ))
    }
}

private enum RuntimeTopicBuilder {
    static func subscribeAllOneWayTopics(namespace: String) -> String {
        "coaty/3/\(namespace)/+/+"
    }

    static func subscribeTopic(eventType: WireEventType, namespace: String) -> String {
        let correlation = eventType.isOneWay ? "" : "/+"
        return "coaty/3/\(namespace)/\(eventType.rawValue)/+\(correlation)"
    }
}
