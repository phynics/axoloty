// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  MQTTNIOClient.swift
//  Axoloty
//
//

import ErrorKit
import Foundation
import Logging
@preconcurrency import MQTTNIO
import NIO
import NIOConcurrencyHelpers

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
/// ``Broadcast`` streams.
///
/// - Note: mqtt-nio's `MQTTClient` exposes an `EventLoopFuture`-based API with a
///   named-listener registration model for incoming PUBLISH messages (not
///   async/await, and not delegate-based in the `NSObjectProtocol` sense used by
///   CocoaMQTT) — see `addPublishListener(named:_:)`/`addCloseListener(named:_:)`.
///   Those listener callbacks are plain synchronous closures, so they bridge
///   directly into the synchronous delegate and ``Broadcast`` surfaces.
internal class MQTTNIOClient: CommunicationClient {

    private let log = LogManager.logger(.mqtt)

    // MARK: - Protocol fields.

    var delegate: CommunicationClientDelegate

    /// Typed broadcast streams that mirror communication state and raw MQTT
    /// transport messages to concurrent consumers.
    ///
    /// Created by ``CommunicationManager`` (which owns the subscription
    /// coordinator needed for `onFirst`/`onLast` hooks) and set on this
    /// client via ``setStreams(_:)`` before it starts producing values.
    ///
    /// Held as an optional rather than an implicitly-unwrapped optional so
    /// that an inbound message arriving before ``setStreams(_:)`` is logged
    /// and dropped (see ``streamsOrWarn()``) instead of trapping. In
    /// practice ``CommunicationManager`` calls `setStreams` in its `init`,
    /// before `connect()`, so this is nil only under a misordered
    /// initialization.
    var streams: CommunicationStreams?

    func setStreams(_ streams: CommunicationStreams) {
        self.streams = streams
    }

    /// Returns the broadcast streams if set, otherwise logs a warning and
    /// returns nil so an inbound message can be dropped without trapping.
    /// `setStreams` is called in ``CommunicationManager.init`` before
    /// `connect()`, so a nil return indicates a misordered initialization.
    private func streamsOrWarn() -> CommunicationStreams? {
        guard let streams else {
            log.warning("Streams not set; dropping incoming MQTT message")
            return nil
        }
        return streams
    }

    /// mqtt-nio MQTT client for the currently targeted broker candidate.
    ///
    /// - Note: mqtt-nio's `host`/`port` are immutable (`let`) properties of
    ///   `MQTTClient`, unlike CocoaMQTT's mutable `host`/`port` vars. Broker
    ///   candidate fallback therefore recreates the client instance targeting
    ///   the next candidate (see `connectNext()`) instead of mutating the
    ///   existing instance in place.
    ///
    /// Mutable connection-lifecycle state is guarded by ``lock`` so concurrent
    /// callers (the close listener, mDNS discovery, `disconnect`, and I/O
    /// methods) never read a half-transitioned reference or flag. The lock is
    /// never held across an `await` or an NIO future: callers snapshot the
    /// needed state under the lock, release it, then operate on the snapshot.
    private let lock = NIOLock(), lifecycle = LifecycleState()

    private var mqttClientOptions: MQTTClientOptions!, configuration: MQTTClient.Configuration!
    private var qos: MQTTQoS = .atMostOnce
    private var discovery: ServiceDiscovery?

    /// Serializes delivery of decoded MQTT messages into ``Broadcast`` in
    /// arrival order.
    ///
    /// mqtt-nio's publish listener fires synchronously per message on its
    /// event loop, but each per-message broadcast send is `async` (`Broadcast` is
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

    /// Mutable connection-lifecycle state guarded by ``lock``. Grouped into one
    /// box so every read/write of the client reference, connection flags, and
        /// reconnect work item is a single locked critical section, never split across a
    /// suspension point.
    private final class LifecycleState {
        /// The currently targeted broker candidate's mqtt-nio client.
        var client: MQTTClient?

        /// Last-will (topic, message) as passed to
        /// `connect(lastWillTopic:lastWillMessage:)`, reapplied on reconnect
        /// (broker candidate fallback or auto-reconnect).
        var lastWill: (topic: String, message: String)?

        /// Guards against overlapping connection attempts (mqtt-nio has no
        /// CocoaMQTT-style `connState` to query directly).
        var isConnecting = false

        /// Correlates every attempt of one connect/reconnect sequence (broker
        /// candidate fallback and `autoReconnect` retries) under a single id.
        /// Minted the first time `performConnect()` runs after the previous
        /// sequence concluded (success or intentional disconnect), and cleared
        /// on the same conditions -- so a dropped connection that triggers
        /// several retries logs one id throughout, and the *next* drop gets a
        /// fresh one.
        var connectionAttemptId: String?

        /// Set right before an explicit, user-requested `disconnect()` so the
        /// close-listener (which fires on *any* connection close, intentional or
        /// not) can distinguish it from a dropped connection and skip
        /// auto-reconnect/broker-candidate fallback. Cleared only by the close
        /// listener; reconnect paths refuse to proceed while this is set.
        var isIntentionalDisconnect = false

        /// Pending broker host candidates for failover.
        var brokerCandidates = [String]()

        /// Port shared by all broker candidates.
        var brokerPort: UInt16 = 1883

        /// The delayed reconnect work item, retained so `disconnect()`,
        /// `replaceClient()`, and `deinit` can cancel it and prevent a
        /// reconnect after an explicit disconnect.
        var reconnectWorkItem: DispatchWorkItem?

        /// Identifies the reconnect work item that is still entitled to run.
        /// Clearing or replacing it retires the previous callback even if its
        /// queue cancellation races with execution.
        var reconnectToken: UUID?
    }

    // MARK: - Initializer.

    init(mqttClientOptions: MQTTClientOptions, delegate: CommunicationClientDelegate) {
        self.delegate = delegate

        let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream()
        self.deliveryContinuation = continuation
        self.deliveryTask = _Concurrency.Task<Void, Never>(priority: .userInitiated) {
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
        // deinit runs with exclusive access to the instance, so the lifecycle
        // state is read without the lock. Cancel any pending reconnect work item so it
        // cannot fire after the client is gone, then flip mqtt-nio's internal
        // `isShutdown` flag synchronously, which is enough to satisfy its
        // deinit precondition even though the rest of shutdown completes
        // asynchronously.
        lifecycle.reconnectWorkItem?.cancel()
        lifecycle.client?.shutdown(queue: .global()) { _ in }
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

        let client = makeClient(host: mqttClientOptions.host, port: Int(mqttClientOptions.port))
        attachListeners(to: client)
        lock.withLock { lifecycle.client = client }
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
        // `shouldLog` is an additional early-exit for mqtt-nio's own verbose
        // wire-protocol logging, not a replacement for `log`'s level gating
        // -- when enabled, mqtt-nio logs through the same per-subsystem
        // logger and level store as the rest of this client.
        MQTTClient(
            host: host,
            port: port,
            identifier: mqttClientOptions.clientId!,
            eventLoopGroupProvider: .shared(eventLoopGroup),
            logger: mqttClientOptions.shouldLog ? log : nil,
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
        lock.withLock { lifecycle.lastWill = (lastWillTopic, lastWillMessage) }
        performConnect()
    }

    /// Connects (or reconnects) the current client using the stored last-will,
    /// guarding against overlapping connection attempts. Refuses to proceed
    /// while an intentional disconnect is active.
    private func performConnect() {
        // Atomic check-and-set of `isConnecting`, an intentional-disconnect
        // guard, and a client/attemptId snapshot all under one lock, so a
        // concurrent `disconnect()` or second `performConnect()` cannot slip
        // between the check and the set. NIO's `client.connect(...)` runs
        // outside the lock on the snapshot.
        let snapshot = lock.withLock { () -> (client: MQTTClient, attemptId: String)? in
            guard !lifecycle.isIntentionalDisconnect else {
                return nil
            }
            guard let client = lifecycle.client,
                  !client.isActive() && !lifecycle.isConnecting else {
                return nil
            }
            lifecycle.isConnecting = true
            let attemptId = lifecycle.connectionAttemptId ?? {
                let id = CoatyUUID().string
                lifecycle.connectionAttemptId = id
                return id
            }()
            return (client, attemptId)
        }
        guard let snapshot else {
            return
        }

        let client = snapshot.client
        let attemptId = snapshot.attemptId
        let will = lock.withLock { lifecycle.lastWill }.map {
            (topicName: $0.topic, payload: byteBuffer(from: $0.message), qos: qos, retain: false)
        }
        log.debug("Connecting to broker", metadata: [
            "correlationId": .string(attemptId),
            "broker": "\(client.host):\(client.port)",
        ])

        client.connect(cleanSession: true, will: will).whenComplete { [weak self] result in
            guard let self = self else {
                return
            }
            // If an explicit disconnect() retired this attempt while it was in
            // flight, abandon the result: do not go .online and do not
            // reconnect. disconnect() clears connectionAttemptId, so a mismatch
            // (nil or a newer id) means this attempt no longer owns the
            // lifecycle -- and this check is robust to handleClose having
            // already cleared isIntentionalDisconnect, which would otherwise
            // let the failure path's scheduleReconnect fire after a disconnect.
            let superseded = self.lock.withLock { () -> Bool in
                self.lifecycle.isConnecting = false
                return self.lifecycle.connectionAttemptId != attemptId
            }
            if superseded {
                // A failed connect fires no close listener, so clear the
                // intentional-disconnect flag here to unblock future connects.
                // A successful connect's close is cleared by handleClose; do
                // not clear it here or a later close of the superseded
                // connection would be treated as a dropped connection.
                if case .failure = result {
                    self.lock.withLock { self.lifecycle.isIntentionalDisconnect = false }
                }
                self.log.notice("Abandoning connection result; attempt superseded by disconnect", metadata: [
                    "correlationId": .string(attemptId),
                    "broker": "\(client.host):\(client.port)",
                ])
                return
            }
            switch result {
            case .success:
                self.log.info("Connected to broker", metadata: [
                    "correlationId": .string(attemptId),
                    "broker": "\(client.host):\(client.port)",
                ])
                self.lock.withLock { self.lifecycle.connectionAttemptId = nil }
                self.updateCommunicationState(.online)
            case .failure(let error):
                self.log.notice("Connection error", metadata: [
                    "correlationId": .string(attemptId),
                    "broker": "\(client.host):\(client.port)",
                    "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
                ])
                // A refused/failed connect attempt never established a
                // connection, so mqtt-nio's close listener (handleClose)
                // does not fire for it. Without an explicit retry here, one
                // failed attempt -- e.g. while a restarting broker is not
                // yet accepting connections -- would permanently end
                // auto-reconnect, contradicting handleClose's documented
                // fallback contract. `connectNext`/`scheduleReconnect` re-check
                // `isIntentionalDisconnect` so a disconnect during the
                // connect attempt is honored.
                let hasCandidates = self.lock.withLock { !self.lifecycle.brokerCandidates.isEmpty }
                if hasCandidates {
                    self.connectNext()
                } else if self.mqttClientOptions.autoReconnect {
                    self.scheduleReconnect()
                }
            }
        }
    }

    /// Switches to the next broker candidate (mirrors CocoaMQTTClient's
    /// `connectNext()`), recreating the client instance since mqtt-nio's
    /// `host`/`port` are immutable. Refuses to proceed while an intentional
    /// disconnect is active.
    private func connectNext() {
        let next = lock.withLock { () -> (host: String, port: Int)? in
            guard !lifecycle.isIntentionalDisconnect else {
                return nil
            }
            guard !lifecycle.brokerCandidates.isEmpty else {
                return nil
            }
            let host = lifecycle.brokerCandidates.removeFirst()
            return (host, Int(lifecycle.brokerPort))
        }
        guard let next else {
            return
        }
        replaceClient(host: next.host, port: next.port)
        performConnect()
    }

    private func replaceClient(host: String, port: Int) {
        let newClient = makeClient(host: host, port: port)
        attachListeners(to: newClient)
        // Swap the client reference, read the pending reconnect task, and nil
        // it in one critical section so a scheduleReconnect racing the swap
        // cannot install a task targeting the new client only to be cancelled.
        let (oldClient, reconnectWorkItem) = lock.withLock { () -> (MQTTClient?, DispatchWorkItem?) in
            let old = lifecycle.client
            lifecycle.client = newClient
            let workItem = lifecycle.reconnectWorkItem
            lifecycle.reconnectWorkItem = nil
            lifecycle.reconnectToken = nil
            return (old, workItem)
        }
        // Cancel any pending reconnect against the old client outside the lock,
        // then gracefully shut down the replaced client; it shares this object's
        // `eventLoopGroup`, so shutdown only closes its connection and satisfies
        // mqtt-nio's shutdown-before-deinit precondition without touching the
        // shared event loop group.
        reconnectWorkItem?.cancel()
        oldClient?.shutdown(queue: .global()) { _ in }
    }

    func disconnect() {
        // Mark the disconnect, clear the attempt id, and snapshot the client and
        // pending reconnect work item under one lock so a racing reconnect path
        // observes the intentional-disconnect flag. The close listener is the
        // only path that later clears `isIntentionalDisconnect`.
        let snapshot = lock.withLock { () -> (client: MQTTClient?, reconnectWorkItem: DispatchWorkItem?) in
            lifecycle.isIntentionalDisconnect = true
            lifecycle.connectionAttemptId = nil
            let client = lifecycle.client
            let workItem = lifecycle.reconnectWorkItem
            lifecycle.reconnectWorkItem = nil
            lifecycle.reconnectToken = nil
            return (client, workItem)
        }
        // Cancel the pending reconnect outside the lock; its retired token
        // also prevents execution if queue cancellation races with dispatch.
        snapshot.reconnectWorkItem?.cancel()
        let log = self.log
        snapshot.client?.disconnect().whenFailure { error in
            log.debug("Error while disconnecting", metadata: [
                "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
            ])
        }
    }

    func publish(_ topic: String, message: String) {
        log.trace("Publishing", metadata: ["topic": .string(topic), "qos": "\(qos)"])
        let client = lock.withLock { lifecycle.client }
        let log = self.log
        client?.publish(to: topic, payload: byteBuffer(from: message), qos: qos, retain: false)
            .whenFailure { error in
                log.warning("Error publishing", metadata: [
                    "topic": .string(topic),
                    "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
                ])
            }
    }

    func publish(_ topic: String, message: [UInt8]) {
        // NOTE: preserves a pre-existing quirk of the former CocoaMQTTClient:
        // this overload always publishes at QoS 0, unretained, regardless of
        // `mqttClientOptions.qos`. Not changed here; flagged, not silently
        // "fixed".
        log.trace("Publishing", metadata: ["topic": .string(topic), "qos": "atMostOnce"])
        let client = lock.withLock { lifecycle.client }
        let log = self.log
        client?.publish(to: topic, payload: byteBuffer(from: message), qos: .atMostOnce, retain: false)
            .whenFailure { error in
                log.warning("Error publishing", metadata: [
                    "topic": .string(topic),
                    "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
                ])
            }
    }

    @MainActor func subscribe(_ topic: String) async throws {
        let client = lock.withLock { lifecycle.client }
        guard let client else {
            throw AxolotyError.runtime(code: .notStarted, reason: "Cannot subscribe before the MQTT client is initialized.")
        }
        do {
            _ = try await client.subscribe(
                to: [MQTTSubscribeInfo(topicFilter: topic, qos: qos)]
            ).get()
            log.debug("Subscribed to topic", metadata: ["topic": .string(topic)])
        } catch {
            throw AxolotyError.network(
                error: error,
                reason: "Error subscribing to topic \(topic)"
            )
        }
    }

    @MainActor func unsubscribe(_ topic: String) async throws {
        let client = lock.withLock { lifecycle.client }
        guard let client else {
            throw AxolotyError.runtime(code: .notStarted, reason: "Cannot unsubscribe before the MQTT client is initialized.")
        }
        do {
            try await client.unsubscribe(from: [topic]).get()
            log.debug("Unsubscribed from topic", metadata: ["topic": .string(topic)])
        } catch {
            throw AxolotyError.network(
                error: error,
                reason: "Error unsubscribing from topic \(topic)"
            )
        }
    }

    // MARK: - State management methods.

    func updateCommunicationState(_ state: CommunicationState) {
        delegate.didUpdateCommunicationState(state)

        guard let streams = streamsOrWarn() else {
            return
        }
        deliveryContinuation.yield {
            await streams.communicationState.sendState(state)
        }
    }

    // MARK: - mqtt-nio listener callbacks.

    /// Processes one mqtt-nio PUBLISH at the synchronous-to-async ownership
    /// boundary.
    ///
    /// mqtt-nio owns `info.payload` only for this listener callback. This
    /// method first copies it into `[UInt8]`, then uses `TopicView` only inside
    /// the scoped `String.withUTF8` borrow to make routing decisions and
    /// materialize `ParsedMQTTMessage` metadata as `String`s. Every closure
    /// yielded to ``deliveryContinuation`` captures only owned `Sendable`
    /// values (`RawMQTTMessage`, `IoValueEventSnapshot`, or
    /// `ParsedMQTTMessage`), never `TopicView`, `ByteSlice`, or
    /// `BorrowedMessage`.
    func handlePublish(_ result: Result<MQTTPublishInfo, Swift.Error>) {
        switch result {
        case .success(let info):
            let bytes = [UInt8](info.payload.readableBytesView)
            let rawMessage = RawMQTTMessage(topic: info.topicName, payload: bytes)
            guard let streams = streamsOrWarn() else {
                return
            }
            deliveryContinuation.yield {
                await streams.rawMQTTMessages.send(rawMessage)
            }

            var topicName = info.topicName
            topicName.withUTF8 { topicBuf in
                guard let base = topicBuf.baseAddress else { return }
                let topicView = TopicView(topicBytes: base, length: topicBuf.count)

                if topicView.isRawTopic {
                    self.delegate.didReceiveRawMQTTMessage(
                        topic: info.topicName,
                        payload: bytes
                    )
                    return
                }

                if topicView.eventType == .ioValue {
                    self.delegate.didReceiveIoValue(
                        topic: info.topicName,
                        payload: bytes
                    )
                    deliveryContinuation.yield {
                        await streams.ioValues.send(IoValueEventSnapshot(topic: info.topicName, payload: bytes))
                    }
                    return
                }

                guard let wireType = topicView.eventType else {
                    log.warning("Ignoring incoming event", metadata: [
                        "topic": .string(info.topicName),
                    ])
                    return
                }

                var receivedEventMetadata: Logging.Logger.Metadata = [
                    "topic": .string(info.topicName),
                    "eventType": .string(wireType.rawValue),
                ]
                if let corrIdSlice = topicView.correlationIdLevel {
                    receivedEventMetadata["correlationId"] = .string(corrIdSlice.asString())
                }
                log.trace("Received event", metadata: receivedEventMetadata)

                guard let payloadString = Self.validUTF8Payload(from: info.payload) else {
                    log.warning("Dropping incoming MQTT message with invalid UTF-8 payload", metadata: [
                        "topic": .string(info.topicName),
                    ])
                    return
                }
                let parsed = ParsedMQTTMessage(topicView: topicView, payload: payloadString)
                deliveryContinuation.yield {
                    await streams.parsedMQTTMessages.send(parsed)
                    await Self.routeParsedMessage(parsed: parsed, into: streams)
                }
            }
        case .failure(let error):
            log.warning("Error receiving published message", metadata: [
                "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
            ])
        }
    }

    /// Returns the payload as a UTF-8 string without first copying it into an array.
    ///
    /// This preserves `String(bytes:encoding:)`'s rejection of invalid UTF-8,
    /// unlike the lossy `String(decoding:as:)` initializer.
    static func validUTF8Payload(from payload: ByteBuffer) -> String? {
        String(validating: payload.readableBytesView, as: UTF8.self)
    }

    /// Routes a parsed MQTT message to the appropriate event streams.
    ///
    /// This is the single routing decision point for all non-IoValue, non-raw
    /// Coaty messages. The exhaustive switch ensures that adding a new event
    /// type produces a compiler error here.
    ///
    /// - Parameters:
    ///   - parsed: the parsed transport message.
    ///   - streams: the communication streams to dispatch into.
    internal static func routeParsedMessage(
        parsed: ParsedMQTTMessage,
        into streams: CommunicationStreams
    ) async {
        switch parsed.eventType {
        case .advertise:
            guard let snapshot = AdvertiseEventSnapshot(parsedMQTTMessage: parsed) else { return }
            let baseKey = AdvertiseKey(eventTypeFilter: parsed.eventTypeFilter ?? "")
            await streams.advertiseFamily.send(snapshot, for: baseKey)
            if let coreType = CoreType.getCoreType(forObjectType: snapshot.object.objectType),
               parsed.eventTypeFilter == coreType.rawValue {
                let objectKey = AdvertiseKey(
                    eventTypeFilter: coreType.rawValue,
                    objectTypeFilter: snapshot.object.objectType
                )
                await streams.advertiseFamily.send(snapshot, for: objectKey)
            }
        case .deadvertise:
            if let snapshot = DeadvertiseEventSnapshot(parsedMQTTMessage: parsed) {
                await streams.deadvertise.send(snapshot)
            }
        case .discover:
            if let snapshot = DiscoverEventSnapshot(parsedMQTTMessage: parsed) {
                await streams.discover.send(snapshot)
            }
        case .query:
            if let snapshot = QueryEventSnapshot(parsedMQTTMessage: parsed) {
                await streams.query.send(snapshot)
            }
        case .call:
            if let snapshot = CallEventSnapshot(parsedMQTTMessage: parsed),
               let operation = parsed.eventTypeFilter {
                await streams.callFamily.send(snapshot, for: operation)
            }
        case .complete, .resolve, .retrieve, .returnEvent:
            if let correlationId = parsed.correlationId {
                let snapshot = ResponseEventSnapshot(
                    eventType: parsed.eventType.rawValue,
                    sourceId: parsed.sourceId,
                    correlationId: correlationId,
                    payload: parsed.payload
                )
                await streams.responseFamily.send(
                    snapshot,
                    for: ResponseKey(eventType: parsed.eventType, correlationId: correlationId)
                )
            }
        case .update:
            guard let snapshot = UpdateEventSnapshot(parsedMQTTMessage: parsed),
                  let filter = parsed.eventTypeFilter else { return }
            await streams.updateFamily.send(snapshot, for: filter)
        case .channel:
            guard let snapshot = ChannelEventSnapshot(parsedMQTTMessage: parsed),
                  let channelId = parsed.eventTypeFilter else { return }
            await streams.channelFamily.send(snapshot, for: channelId)
        case .associate:
            guard let snapshot = AssociateEventSnapshot(parsedMQTTMessage: parsed),
                  let contextName = snapshot.ioContextName else { return }
            await streams.associateFamily.send(snapshot, for: contextName)
        case .ioValue:
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

        // Only the close listener clears the intentional-disconnect flag, so a
        // reconnect path racing with `disconnect()` still observes it. Read the
        // fallback decision under the same lock.
        let (shouldReconnect, hasCandidates) = lock.withLock { () -> (Bool, Bool) in
            if lifecycle.isIntentionalDisconnect {
                lifecycle.isIntentionalDisconnect = false
                return (false, false)
            }
            return (true, !lifecycle.brokerCandidates.isEmpty)
        }
        guard shouldReconnect else {
            return
        }
        if hasCandidates {
            connectNext()
        } else if mqttClientOptions.autoReconnect {
            scheduleReconnect()
        }
    }
}

private extension MQTTNIOClient {

    func scheduleReconnect() {
        let delaySeconds = max(mqttClientOptions.autoReconnectTimeInterval, 0)
        let token = UUID()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            // Re-check after the delay: a disconnect or replacement that raced
            // with queue cancellation retires this callback's token, so no
            // reconnect fires after explicit teardown.
            let mayReconnect = self.lock.withLock { () -> Bool in
                guard self.lifecycle.reconnectToken == token,
                      !self.lifecycle.isIntentionalDisconnect else {
                    return false
                }
                self.lifecycle.reconnectToken = nil
                self.lifecycle.reconnectWorkItem = nil
                return true
            }
            guard mayReconnect else {
                return
            }
            self.performConnect()
        }
        // Retain the work item so disconnect()/replaceClient()/deinit can
        // cancel it, cancelling any previously scheduled reconnect first. The
        // intentional-disconnect check and installation share one critical
        // section so disconnect cannot miss a just-created reconnect.
        let scheduling = lock.withLock { () -> (shouldSchedule: Bool, previous: DispatchWorkItem?) in
            guard !lifecycle.isIntentionalDisconnect else {
                return (false, nil)
            }
            let previous = lifecycle.reconnectWorkItem
            lifecycle.reconnectWorkItem = workItem
            lifecycle.reconnectToken = token
            return (true, previous)
        }
        guard scheduling.shouldSchedule else {
            return
        }
        scheduling.previous?.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delaySeconds), execute: workItem)
    }
}

extension MQTTNIOClient: ServiceDiscoveryDelegate {

    func didReceiveService(addresses: [String], port: Int) {
        discovery?.stopDiscovery()

        let first = lock.withLock { () -> (host: String, port: Int) in
            lifecycle.brokerCandidates.append(contentsOf: addresses)
            lifecycle.brokerPort = UInt16(port)
            let host = lifecycle.brokerCandidates.removeFirst()
            return (host, Int(lifecycle.brokerPort))
        }
        replaceClient(host: first.host, port: first.port)

        delegate.didReceiveStart()
    }
}
