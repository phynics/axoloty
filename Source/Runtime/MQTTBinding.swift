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
    private let client: MQTTNIOClient
    private let delegate: RuntimeMQTTDelegate
    private let connectionTimeoutMS: UInt32
    private let routeClassifier = ExactProtocolRouteClassifier(
        externalRoute: "external/wire-compat-v1/io-external-1"
    )
    private var started = false

    /// Creates a binding backed by the repository's MQTTNIO implementation.
    public init(configuration: MQTTBindingConfiguration) throws {
        let delegate = RuntimeMQTTDelegate()
        let options = MQTTClientOptions(
            host: configuration.host,
            port: configuration.port,
            enableSSL: configuration.usesTLS,
            shouldTryMDNSDiscovery: false,
            username: configuration.username,
            password: configuration.password,
            autoReconnect: false,
            autoReconnectTimeInterval: 1,
            qos: 0,
            shouldLog: false
        )
        options.clientId = "axoloty-runtime-\(UUID().uuidString)"
        self.delegate = delegate
        self.connectionTimeoutMS = configuration.connectionTimeoutMS
        self.client = try MQTTNIOClient(mqttClientOptions: options, delegate: delegate)
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
                client.connect(lastWillTopic: "", lastWillMessage: "")
            }
        } catch {
            lock.withLock { started = false }
            client.disconnect()
            delegate.clearReceive()
            throw error
        }
    }

    /// Publishes one normalized action using the canonical Coaty topic shape.
    public func send(_ action: OwnedProtocolAction, namespace: String) async throws {
        guard lock.withLock({ started }) else {
            throw AxolotyError.runtime(code: .notStarted, reason: "MQTT binding is not started")
        }
        let topic = Self.topic(for: action.routingKey, namespace: namespace)
        client.publish(topic, message: action.payload)
    }

    /// Stops the MQTT connection and releases callback admission.
    public func stop() async {
        lock.withLock { started = false }
        delegate.failStart(AxolotyError.runtime(code: .cancelled, reason: "MQTT binding stopped while connecting"))
        client.disconnect()
        delegate.clearReceive()
    }

    /// Installs bounded wildcard subscriptions for the closed profile.
    public func installSubscriptions(namespace: String) async throws {
        try await client.subscribe(TopicBuilder.subscribeAllOneWayTopics(namespace: namespace))
        let responseFamilies: [WireEventType] = [.discover, .resolve, .query, .retrieve, .update, .complete, .call, .returnEvent]
        for family in responseFamilies {
            try await client.subscribe(TopicBuilder.subscribeTopic(eventType: family, namespace: namespace))
        }
    }

    /// Removes the same profile subscriptions during shutdown/reconnect.
    public func removeSubscriptions(namespace: String) async throws {
        try await client.unsubscribe(TopicBuilder.subscribeAllOneWayTopics(namespace: namespace))
        let responseFamilies: [WireEventType] = [.discover, .resolve, .query, .retrieve, .update, .complete, .call, .returnEvent]
        for family in responseFamilies {
            try await client.unsubscribe(TopicBuilder.subscribeTopic(eventType: family, namespace: namespace))
        }
    }

    /// Publishes a minimal modern Identity advertisement before runtime ready.
    public func advertise(identity: RuntimeIdentity?, namespace: String) async throws {
        guard let identity else { return }
        let payload = try Self.identityPayload(identity)
        let key = try ProtocolRoutingKey(capability: .advertise, sourceID: identity.id)
        client.publish(Self.topic(for: key, namespace: namespace), message: payload)
    }

    /// Publishes a matching Deadvertise payload during graceful shutdown.
    public func deadvertise(identity: RuntimeIdentity?, namespace: String) async throws {
        guard let identity else { return }
        let payload = Array("[\"\(Self.uuidString(identity.id))\"]".utf8)
        let key = try ProtocolRoutingKey(capability: .deadvertise, sourceID: identity.id)
        client.publish(Self.topic(for: key, namespace: namespace), message: payload)
    }

    /// Classifies the binding's exact external compatibility route.
    public func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification {
        routeClassifier.classify(route)
    }

    private static func topic(for key: ProtocolRoutingKey, namespace: String) -> String {
        var topic = "coaty/3/\(namespace)/\(key.capability.wireEventType.rawValue)/\(uuidString(key.sourceID))"
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

    private static func uuidString(_ value: UUID16) -> String {
        let bytes = value.bytes
        let raw: [UInt8] = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7, bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15]
        let hex = raw.map { String(format: "%02x", $0) }
        return "\(hex[0])\(hex[1])\(hex[2])\(hex[3])\(hex[4])\(hex[5])\(hex[6])\(hex[7])-\(hex[8])\(hex[9])-\(hex[10])\(hex[11])-\(hex[12])\(hex[13])-\(hex[14])\(hex[15])\(hex[16])\(hex[17])\(hex[18])\(hex[19])\(hex[20])\(hex[21])\(hex[22])\(hex[23])\(hex[24])\(hex[25])\(hex[26])\(hex[27])\(hex[28])\(hex[29])\(hex[30])\(hex[31])"
    }
}

private final class RuntimeMQTTDelegate: CommunicationClientDelegate, @unchecked Sendable {
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

    func didReceiveStart() {}

    func didUpdateCommunicationState(_ state: CommunicationState) {
        guard state == .online else {
            if state == .offline {
                finishStart(.failure(AxolotyError.runtime(
                    code: .brokerUnavailable,
                    reason: "MQTT broker connection failed before the runtime became online"
                )))
            }
            return
        }
        finishStart(.success(()))
    }

    func failStart(_ error: Error) {
        finishStart(.failure(error))
    }

    private func finishStart(_ result: Result<Void, Error>) {
        let (continuation, timeoutTask): (CheckedContinuation<Void, Error>?, Task<Void, Never>?) = lock.withLock {
            let continuation = startContinuation
            let timeoutTask = startTimeoutTask
            startContinuation = nil
            startTimeoutTask = nil
            return (continuation, timeoutTask)
        }
        timeoutTask?.cancel()
        guard let continuation else { return }
        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    func didReceiveRawMQTTMessage(topic: String, payload: [UInt8]) {
        let callback = lock.withLock { receive }
        callback?(RuntimeInboundFrame(topic: topic, payload: payload))
    }

    func didReceiveIoValue(topic: String, payload: [UInt8]) {
        let callback = lock.withLock { receive }
        callback?(RuntimeInboundFrame(topic: topic, payload: payload))
    }
}
