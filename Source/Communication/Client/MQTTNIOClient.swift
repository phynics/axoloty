// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  MQTTNIOClient.swift
//  Axoloty
//
//

import ErrorKit
import Foundation
import Logging
import MQTTNIO
import NIO

#if canImport(Network)
import Network
import NIOTransportServices
#else
import NIOSSL
#endif

/// Default MQTT client for networking, backed by `swift-server-community/mqtt-nio`
/// (SwiftNIO based, pure Swift, Linux-native).
///
/// This class replaces the former CocoaMQTT-backed implementation. It keeps the
/// transport events are delivered through the manager delegate and async
/// ``EventHub`` streams.
///
/// - Note: mqtt-nio's `MQTTClient` exposes an `EventLoopFuture`-based API with a
///   named-listener registration model for incoming PUBLISH messages (not
///   async/await, and not delegate-based in the `NSObjectProtocol` sense used by
///   CocoaMQTT) — see `addPublishListener(named:_:)`/`addCloseListener(named:_:)`.
///   Those listener callbacks are plain synchronous closures, so they bridge
///   directly into the synchronous delegate and ``EventHub`` surfaces.
internal class MQTTNIOClient: CommunicationClient, @unchecked Sendable {

    private let log = LogManager.log

    // MARK: - Protocol fields.

    var delegate: CommunicationClientDelegate

    /// The async event hub used to mirror communication state and raw MQTT
    /// transport messages to concurrent consumers.
    ///
    /// - Note: This hub is intentionally owned by the client so that its
    ///   lifetime matches the underlying transport and so that state streams
    ///   replay the last known state even before a subscriber attaches.
    let eventHub = EventHub()

    var brokerCandidates = [String]()
    var brokerPort: UInt16 = 1883

    /// mqtt-nio MQTT client for the currently targeted broker candidate.
    ///
    /// - Note: mqtt-nio's `host`/`port` are immutable (`let`) properties of
    ///   `MQTTClient`, unlike CocoaMQTT's mutable `host`/`port` vars. Broker
    ///   candidate fallback therefore recreates the client instance targeting
    ///   the next candidate (see `connectNext()`) instead of mutating the
    ///   existing instance in place.
    private var client: MQTTClient!
    private var mqttClientOptions: MQTTClientOptions!
    private var configuration: MQTTClient.Configuration!
    private var qos: MQTTQoS = .atMostOnce
    private var discovery: ServiceDiscovery?

    /// Last-will (topic, message) as passed to `connect(lastWillTopic:lastWillMessage:)`,
    /// reapplied whenever the client reconnects (broker candidate fallback or
    /// auto-reconnect).
    private var lastWill: (topic: String, message: String)?

    /// Guards against overlapping connection attempts (mqtt-nio has no
    /// CocoaMQTT-style `connState` to query directly).
    private var isConnecting = false

    /// Set right before an explicit, user-requested `disconnect()` so the
    /// close-listener (which fires on *any* connection close, intentional or
    /// not) can distinguish it from a dropped connection and skip
    /// auto-reconnect/broker-candidate fallback.
    private var isIntentionalDisconnect = false

    /// Serializes delivery of decoded MQTT messages into ``EventHub`` in
    /// arrival order.
    ///
    /// mqtt-nio's publish listener fires synchronously per message on its
    /// event loop, but each per-message hub yield is `async` (`EventHub` is
    /// an actor). Spawning an unstructured `Task` per message let
    /// independently-scheduled tasks race for actor execution, so messages
    /// could reach the hub out of arrival order -- a regression from the
    /// RxSwift-era sequential dispatch. `AsyncStream.Continuation.yield` is
    /// synchronous and preserves call order, so feeding one and draining it
    /// from a single long-lived `Task` restores that guarantee. See issue
    /// #56.
    private let deliveryContinuation: AsyncStream<@Sendable () async -> Void>.Continuation
    private let deliveryTask: _Concurrency.Task<Void, Never>

    /// Shared event loop group for all `MQTTClient` instances created by this
    /// object (one per broker candidate attempt). Using a shared group avoids
    /// spinning up a new thread pool on every broker-candidate fallback.
    ///
    /// On Apple platforms, `NIOTSEventLoopGroup` (Network.framework) is
    /// required: mqtt-nio's own bootstrap selection falls back to a
    /// `preconditionFailure` if a plain `MultiThreadedEventLoopGroup` is used
    /// together with the `.ts` TLS configuration path. On Linux, mqtt-nio has
    /// no Network.framework path at all, so a plain `MultiThreadedEventLoopGroup`
    /// (POSIX sockets + NIOSSL for TLS) is used.
    #if canImport(Network)
    private let eventLoopGroup: EventLoopGroup = NIOTSEventLoopGroup(loopCount: 1)
    #else
    private let eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    #endif

    // MARK: - Initializer.

    init(mqttClientOptions: MQTTClientOptions, delegate: CommunicationClientDelegate) {
        self.delegate = delegate

        let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream()
        self.deliveryContinuation = continuation
        self.deliveryTask = _Concurrency.Task<Void, Never> {
            for await job in stream {
                await job()
            }
        }

        configure(mqttClientOptions)

        // `try!` matches the existing fail-fast convention used elsewhere
        // during initialization (see `CommunicationManager.init`).
        // Fail-fast invariant, not user input.
        // swiftlint:disable:next force_try
        try! startDiscoveryIfNeeded(mqttClientOptions)
    }

    deinit {
        deliveryContinuation.finish()
        discovery?.stopDiscovery()
        // Flips mqtt-nio's internal `isShutdown` flag synchronously, which is
        // enough to satisfy its deinit precondition even though the rest of
        // the shutdown completes asynchronously.
        client?.shutdown(queue: .global()) { _ in }
        eventLoopGroup.shutdownGracefully { _ in }
    }

    // MARK: - Helper methods.

    /// Starts mDNS/Bonjour broker discovery if requested by
    /// `mqttClientOptions.shouldTryMDNSDiscovery`.
    ///
    /// - Throws: `AxolotyError.runtime(code: .brokerUnavailable, ...)` if
    ///   discovery is requested but no `ServiceDiscovery` implementation is
    ///   available on the current platform (e.g. non-Apple platforms). In
    ///   that case, configure an explicit broker `host`/`port` instead.
    private func startDiscoveryIfNeeded(_ mqttClientOptions: MQTTClientOptions) throws {
        guard mqttClientOptions.shouldTryMDNSDiscovery else {
            return
        }

        #if canImport(Darwin)
        discovery = BonjourResolver()
        discovery?.delegate = self
        discovery?.startDiscovery()
        #else
        throw AxolotyError.runtime(
            code: .brokerUnavailable,
            reason: "mDNS/Bonjour broker discovery (shouldTryMDNSDiscovery) was requested, but no " +
            "ServiceDiscovery implementation is available on this platform. " +
            "Configure an explicit broker host/port instead."
        )
        #endif
    }

    private func configure(_ mqttClientOptions: MQTTClientOptions) {
        self.mqttClientOptions = mqttClientOptions

        switch mqttClientOptions.qos {
            case 1: self.qos = .atLeastOnce
            case 2: self.qos = .exactlyOnce
            default: self.qos = .atMostOnce
        }

        self.configuration = MQTTClient.Configuration(
            keepAliveInterval: .seconds(Int64(mqttClientOptions.keepAlive)),
            userName: mqttClientOptions.username,
            password: mqttClientOptions.password,
            useSSL: mqttClientOptions.enableSSL,
            tlsConfiguration: tlsConfigurationType(for: mqttClientOptions)
        )

        self.client = makeClient(host: mqttClientOptions.host, port: Int(mqttClientOptions.port))
        attachListeners(to: self.client)
    }

    /// Builds mqtt-nio's TLS configuration type, honoring `enableSSL` and
    /// `allowUntrustCACertificate`. Returns `nil` if TLS is not enabled.
    private func tlsConfigurationType(for mqttClientOptions: MQTTClientOptions) -> MQTTClient.TLSConfigurationType? {
        guard mqttClientOptions.enableSSL else {
            return nil
        }

        #if canImport(Network)
        return .ts(TSTLSConfiguration(
            certificateVerification: mqttClientOptions.allowUntrustCACertificate ? .none : .fullVerification
        ))
        #else
        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.certificateVerification = mqttClientOptions.allowUntrustCACertificate ? .none : .fullVerification
        return .niossl(tlsConfiguration)
        #endif
    }

    private func makeClient(host: String, port: Int) -> MQTTClient {
        MQTTClient(
            host: host,
            port: port,
            identifier: mqttClientOptions.clientId!,
            eventLoopGroupProvider: .shared(eventLoopGroup),
            logger: mqttClientOptions.shouldLog ? Logger(label: "com.coatyswift.mqttnio") : nil,
            configuration: configuration
        )
    }

    private func attachListeners(to client: MQTTClient) {
        client.addPublishListener(named: "coatyswift") { [weak self] result in
            self?.handlePublish(result)
        }
        client.addCloseListener(named: "coatyswift") { [weak self] _ in
            self?.handleClose()
        }
    }

    private func byteBuffer(from string: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: string.utf8.count)
        buffer.writeString(string)
        return buffer
    }

    private func byteBuffer(from bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }

    // MARK: - Communication methods.

    func connect(lastWillTopic: String, lastWillMessage: String) {
        lastWill = (lastWillTopic, lastWillMessage)
        performConnect()
    }

    /// Connects (or reconnects) the current `client` using the stored
    /// last-will, guarding against overlapping connection attempts.
    private func performConnect() {
        guard let client = client else {
            return
        }

        guard !client.isActive() && !isConnecting else {
            return
        }

        isConnecting = true
        log.debug("Connecting to broker host \(client.host) on port \(client.port)")

        let will = lastWill.map {
            (topicName: $0.topic, payload: byteBuffer(from: $0.message), qos: qos, retain: false)
        }

        client.connect(cleanSession: true, will: will).whenComplete { [weak self] result in
            guard let self = self else {
                return
            }
            self.isConnecting = false
            switch result {
            case .success:
                self.updateCommunicationState(.online)
            case .failure(let error):
                self.log.debug("Connection error: \(ErrorKit.errorChainDescription(for: AxolotyError.caught(error)))")
                // A refused/failed connect attempt never established a
                // connection, so mqtt-nio's close listener (handleClose)
                // does not fire for it. Without an explicit retry here, one
                // failed attempt -- e.g. while a restarting broker is not
                // yet accepting connections -- would permanently end
                // auto-reconnect, contradicting handleClose's documented
                // fallback contract.
                if !self.brokerCandidates.isEmpty {
                    self.connectNext()
                } else if self.mqttClientOptions.autoReconnect {
                    self.scheduleReconnect()
                }
            }
        }
    }

    /// Switches to the next broker candidate (mirrors CocoaMQTTClient's
    /// `connectNext()`), recreating the client instance since mqtt-nio's
    /// `host`/`port` are immutable.
    private func connectNext() {
        let nextHost = brokerCandidates.removeFirst()
        replaceClient(host: nextHost, port: Int(brokerPort))
        performConnect()
    }

    private func replaceClient(host: String, port: Int) {
        let oldClient = client
        let newClient = makeClient(host: host, port: port)
        attachListeners(to: newClient)
        client = newClient
        // Gracefully shut down the replaced client (fire-and-forget); it
        // shares this object's `eventLoopGroup`, so this only closes its
        // connection and satisfies mqtt-nio's shutdown-before-deinit
        // precondition, without touching the shared event loop group.
        oldClient?.shutdown(queue: .global()) { _ in }
    }

    private func scheduleReconnect() {
        let delaySeconds = max(mqttClientOptions.autoReconnectTimeInterval, 0)
        _Concurrency.Task<Void, Never> { [weak self] in
            try? await _Concurrency.Task<Never, Never>.sleep(
                nanoseconds: UInt64(delaySeconds) * 1_000_000_000
            )
            self?.performConnect()
        }
    }

    func disconnect() {
        isIntentionalDisconnect = true
        client?.disconnect().whenFailure { [weak self] error in
            self?.log.debug("Error while disconnecting: \(ErrorKit.errorChainDescription(for: AxolotyError.caught(error)))")
        }
    }

    func publish(_ topic: String, message: String) {
        client?.publish(to: topic, payload: byteBuffer(from: message), qos: qos, retain: false)
            .whenFailure { [weak self] error in
                self?.log.warning("Error publishing to \(topic): \(ErrorKit.errorChainDescription(for: AxolotyError.caught(error)))")
            }
    }

    func publish(_ topic: String, message: [UInt8]) {
        // NOTE: preserves a pre-existing quirk of the former CocoaMQTTClient:
        // this overload always publishes at QoS 0, unretained, regardless of
        // `mqttClientOptions.qos`. Not changed here; flagged, not silently
        // "fixed".
        client?.publish(to: topic, payload: byteBuffer(from: message), qos: .atMostOnce, retain: false)
            .whenFailure { [weak self] error in
                self?.log.warning("Error publishing to \(topic): \(ErrorKit.errorChainDescription(for: AxolotyError.caught(error)))")
            }
    }

    func subscribe(_ topic: String) async throws {
        guard let client else {
            throw AxolotyError.runtime(code: .notStarted, reason: "Cannot subscribe before the MQTT client is initialized.")
        }
        do {
            _ = try await client.subscribe(
                to: [MQTTSubscribeInfo(topicFilter: topic, qos: qos)]
            ).get()
            log.debug("Subscribed to topic \(topic).")
        } catch {
            throw AxolotyError.network(
                error: error,
                reason: "Error subscribing to topic \(topic): \(ErrorKit.userFriendlyMessage(for: error))"
            )
        }
    }

    func unsubscribe(_ topic: String) async throws {
        guard let client else {
            throw AxolotyError.runtime(code: .notStarted, reason: "Cannot unsubscribe before the MQTT client is initialized.")
        }
        do {
            try await client.unsubscribe(from: [topic]).get()
            log.debug("Unsubscribed from topic \(topic).")
        } catch {
            throw AxolotyError.network(
                error: error,
                reason: "Error unsubscribing from topic \(topic): \(ErrorKit.userFriendlyMessage(for: error))"
            )
        }
    }

    // MARK: - State management methods.

    func updateCommunicationState(_ state: CommunicationState) {
        delegate.didUpdateCommunicationState(state)

        deliveryContinuation.yield { [weak self] in
            guard let self else { return }
            await self.eventHub.yieldState(
                value: state,
                to: CommunicationEventHubKeys.communicationState
            )
        }
    }

    // MARK: - mqtt-nio listener callbacks.

    private func handlePublish(_ result: Result<MQTTPublishInfo, Swift.Error>) {
        switch result {
        case .success(let info):
            let bytes = [UInt8](info.payload.readableBytesView)
            let rawMessage = RawMQTTMessage(topic: info.topicName, payload: bytes)

            deliveryContinuation.yield { [weak self] in
                guard let self else { return }
                await self.eventHub.yield(
                    value: rawMessage,
                    to: CommunicationEventHubKeys.rawMQTTMessage
                )
            }

            if CommunicationTopic.isRawTopic(topic: info.topicName) {
                self.delegate.didReceiveRawMQTTMessage(
                    topic: info.topicName,
                    payload: bytes
                )
                return
            }

            do {
                let topic = try CommunicationTopic(info.topicName)
                if topic.eventType == .IoValue {
                    self.delegate.didReceiveIoValue(
                        topic: info.topicName,
                        payload: bytes
                    )
                    deliveryContinuation.yield { [weak self] in
                        guard let self else { return }
                        await self.eventHub.yield(
                            value: IoValueEventSnapshot(topic: info.topicName, payload: bytes),
                            to: CommunicationEventHubKeys.ioValue
                        )
                    }
                } else if let payloadString = String(bytes: bytes, encoding: .utf8) {
                    self.delegate.didReceiveMessage(
                        topic: info.topicName,
                        payload: payloadString
                    )

                    let parsed = ParsedMQTTMessage(topic: topic, payload: payloadString)
                    deliveryContinuation.yield { [weak self] in
                        guard let self else { return }
                        await self.eventHub.yield(
                            value: parsed,
                            to: CommunicationEventHubKeys.parsedMQTTMessage
                        )
                        await self.routeAdvertiseSnapshot(parsed: parsed)
                        await self.routeOneWaySnapshot(parsed: parsed)
                        await self.routeSnapshot(parsed: parsed)
                    }
                }
            } catch {
                log.warning("Ignoring incoming event on \(info.topicName): \(ErrorKit.errorChainDescription(for: AxolotyError.caught(error)))")
            }
        case .failure(let error):
            log.warning("Error receiving published message: \(ErrorKit.errorChainDescription(for: AxolotyError.caught(error)))")
        }
    }

    /// Routes a decoded Advertise snapshot to the per-filter event hub keys so
    /// that async observers can consume it without an intermediate dispatcher.
    private func routeAdvertiseSnapshot(parsed: ParsedMQTTMessage) async {
        guard parsed.eventType == .Advertise,
              let snapshot = AdvertiseEventSnapshot(parsedMQTTMessage: parsed) else {
            return
        }

        let baseKey = CommunicationEventHubKeys.advertise(
            eventTypeFilter: parsed.eventTypeFilter ?? ""
        )
        await eventHub.yield(value: snapshot, to: baseKey)

        if let coreType = CoreType.getCoreType(forObjectType: snapshot.object.objectType),
           parsed.eventTypeFilter == coreType.rawValue {
            let objectKey = CommunicationEventHubKeys.advertise(
                eventTypeFilter: coreType.rawValue,
                objectTypeFilter: snapshot.object.objectType
            )
            await eventHub.yield(value: snapshot, to: objectKey)
        }
    }

    private func routeOneWaySnapshot(parsed: ParsedMQTTMessage) async {
        switch parsed.eventType {
        case .Deadvertise:
            if let snapshot = DeadvertiseEventSnapshot(parsedMQTTMessage: parsed) {
                await eventHub.yield(value: snapshot, to: CommunicationEventHubKeys.deadvertise)
            }
        case .Discover:
            if let snapshot = DiscoverEventSnapshot(parsedMQTTMessage: parsed) {
                await eventHub.yield(value: snapshot, to: CommunicationEventHubKeys.discover)
            }
        case .Query:
            if let snapshot = QueryEventSnapshot(parsedMQTTMessage: parsed) {
                await eventHub.yield(value: snapshot, to: CommunicationEventHubKeys.query)
            }
        case .Call:
            if let snapshot = CallEventSnapshot(parsedMQTTMessage: parsed),
               let operation = parsed.eventTypeFilter {
                await eventHub.yield(value: snapshot, to: CommunicationEventHubKeys.call(operation: operation))
            }
        default:
            break
        }
    }

    private func routeSnapshot(parsed: ParsedMQTTMessage) async {
        if let correlationId = parsed.correlationId,
           [.Complete, .Resolve, .Retrieve, .Return].contains(parsed.eventType),
           let payloadData = parsed.payload.data(using: .utf8) {
            let snapshot = ResponseEventSnapshot(
                eventType: parsed.eventType.rawValue,
                sourceId: parsed.sourceId,
                correlationId: correlationId,
                payload: payloadData
            )
            await eventHub.yield(
                value: snapshot,
                to: CommunicationEventHubKeys.response(eventType: parsed.eventType, correlationId: correlationId)
            )
        }
        switch parsed.eventType {
        case .Update:
            guard let snapshot = UpdateEventSnapshot(parsedMQTTMessage: parsed),
                  let filter = parsed.eventTypeFilter else { return }
            await eventHub.yield(value: snapshot, to: CommunicationEventHubKeys.update(eventTypeFilter: filter))
        case .Channel:
            guard let snapshot = ChannelEventSnapshot(parsedMQTTMessage: parsed),
                  let channelId = parsed.eventTypeFilter else { return }
            await eventHub.yield(value: snapshot, to: CommunicationEventHubKeys.channel(channelId: channelId))
        default:
            break
        }
    }

    /// Called whenever the underlying connection closes, whether due to an
    /// explicit `disconnect()`, a dropped connection, or a failed connect
    /// attempt. Mirrors CocoaMQTTClient's `mqttDidDisconnect` delegate method:
    /// updates communication state to `.offline`, then falls back to the next
    /// broker candidate if any are queued, or lets `autoReconnect` retry the
    /// same host after `autoReconnectTimeInterval` seconds.
    private func handleClose() {
        updateCommunicationState(.offline)

        if isIntentionalDisconnect {
            isIntentionalDisconnect = false
            return
        }

        if !brokerCandidates.isEmpty {
            connectNext()
        } else if mqttClientOptions.autoReconnect {
            scheduleReconnect()
        }
    }
}

extension MQTTNIOClient: ServiceDiscoveryDelegate {

    func didReceiveService(addresses: [String], port: Int) {
        discovery?.stopDiscovery()

        brokerCandidates.append(contentsOf: addresses)
        brokerPort = UInt16(port)

        let firstHost = brokerCandidates.removeFirst()
        replaceClient(host: firstHost, port: Int(brokerPort))

        delegate.didReceiveStart()
    }
}
