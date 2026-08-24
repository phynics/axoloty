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

    /// Publishes one normalized publication using its typed target.
    public func send(_ publication: OwnedProtocolPublication, namespace: String) async throws {
        guard lock.withLock({ started }) else {
            throw AxolotyError.runtime(code: .notStarted, reason: "MQTT binding is not started")
        }
        let topic: String
        switch publication.target {
        case .profile(let eventTypeFilter, let eventTypeFilterKind):
            topic = Self.topic(
                for: publication.routingKey,
                namespace: namespace,
                eventTypeFilter: eventTypeFilter,
                eventTypeFilterKind: eventTypeFilterKind
            )
        case .associationRoute(let route, _):
            topic = String(decoding: route, as: UTF8.self)
        }
        try await client.publish(topic: topic, payload: publication.payload)
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
        try await client.unsubscribe(RuntimeTopicBuilder.subscribeAllOneWayTopics(namespace: namespace))
        try await client.unsubscribe(RuntimeTopicBuilder.subscribeAllCorrelatedTopics(namespace: namespace))
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
        let namespaceBytes = Array(namespace.utf8)
        let namespaceStorage = namespaceBytes.isEmpty ? [UInt8(0)] : namespaceBytes
        let filterBytes = eventTypeFilter ?? []
        let filterStorage = filterBytes.isEmpty ? [UInt8(0)] : filterBytes
        let filterLength = eventTypeFilter.map { $0.count + (eventTypeFilterKind == .objectType ? 2 : 1) } ?? 0
        let capacity = 8 + namespaceBytes.count + 1 + 3 + filterLength + 1 + 36 + (key.correlationID == nil ? 0 : 37)
        var bytes = [UInt8](repeating: 0, count: capacity)
        bytes.withUnsafeMutableBufferPointer { output in
            namespaceStorage.withUnsafeBufferPointer { namespace in
                filterStorage.withUnsafeBufferPointer { filter in
                    var builder = TopicBuilder(buffer: output.baseAddress!, capacity: output.count)
                    try! builder.writePrefix()
                    try! builder.writeNamespace(ByteSlice(bytes: namespace.baseAddress!, length: namespaceBytes.count))
                    let filterSlice = eventTypeFilter == nil ? nil : ByteSlice(bytes: filter.baseAddress!, length: filterBytes.count)
                    try! builder.writeEventType(
                        key.capability.wireEventType,
                        filter: filterSlice,
                        filterKind: eventTypeFilterKind == .objectType ? .objectType : .direct
                    )
                    try! builder.writeSourceId(key.sourceID)
                    if let correlationID = key.correlationID { try! builder.writeCorrelationId(correlationID) }
                }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
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
        var bytes = [UInt8](repeating: 0, count: 36)
        bytes.withUnsafeMutableBufferPointer { output in
            var builder = TopicBuilder(buffer: output.baseAddress!, capacity: output.count)
            try! builder.writeSourceId(value)
        }
        return String(decoding: bytes, as: UTF8.self)
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

    static func subscribeAllCorrelatedTopics(namespace: String) -> String {
        "coaty/3/\(namespace)/+/+/+"
    }
}
