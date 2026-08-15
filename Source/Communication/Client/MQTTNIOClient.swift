// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  MQTTNIOClient.swift
//  Axoloty
//
//

import ErrorKit
import Foundation
import Logging
import AxolotyWire
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

    private let callbackAdapter: MQTTNIOCallbackAdapter

    var delegate: CommunicationClientDelegate {
        get { callbackAdapter.delegate }
        set { callbackAdapter.setDelegate(newValue) }
    }

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
    var streams: CommunicationStreams? {
        get { callbackAdapter.streams }
        set {
            if let newValue {
                callbackAdapter.setStreams(newValue)
            }
        }
    }

    func setStreams(_ streams: CommunicationStreams) {
        callbackAdapter.setStreams(streams)
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
    private let lock = NIOLock()

    private var mqttClientOptions: MQTTClientOptions!, configuration: MQTTClient.Configuration!
    private var qos: MQTTQoS = .atMostOnce
    // Allows isolation tests to observe publication arguments without a broker.
    internal typealias PublishHandler = @Sendable (MQTTQoS, Bool) -> Void
    private let publishHandler: PublishHandler?

    /// Injectable seam for connection attempts (mirrors ``PublishHandler``) so
    /// tests can resolve a connect future on demand.
    internal typealias ConnectHandler = @Sendable (MQTTClient) -> EventLoopFuture<Bool>
    private let connectHandler: ConnectHandler?
    private var discovery: ServiceDiscovery?

    /// Serializes delivery of decoded MQTT messages into ``Broadcast`` in
    /// arrival order and bounds the un-delivered backlog so a stalled downstream
    /// router cannot retain inbound payload work without limit.
    ///
    /// mqtt-nio's publish listener fires synchronously per message on its
    /// event loop, but each per-message broadcast send is `async` (`Broadcast` is
    /// an actor). Spawning an unstructured `Task` per message let
    /// independently-scheduled tasks race for actor execution, so messages
    /// could reach the hub out of arrival order -- a regression from the
    /// RxSwift-era sequential dispatch. ``IngressDeliveryQueue`` feeds one
    /// synchronous continuation and drains it from a single long-lived `Task`
    /// to preserve call order (issue #56), and sheds the *newest* queued jobs
    /// once its bounded buffer is full (issue #448). See ``enqueueDelivery(_:)``
    /// for the rate-limited overload reporting this enables.
    let deliveryQueue: IngressDeliveryQueue

    /// Rate-limited overload reporting for the bounded ``deliveryQueue``,
    /// keeping that logging concern out of the queue primitive itself.
    private let overloadReporter = IngressOverloadReporter()

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

    /// Mutable connection-lifecycle state (``LifecycleState``, defined at file
    /// scope) guarded by ``lock``. Grouped into one box so every read/write of the
    /// client reference, connection flags, and reconnect work item is a single
    /// locked critical section, never split across a suspension point.

    private var lifecycle = LifecycleState()

    // MARK: - Initializer.

    /// Creates the MQTT transport client.
    ///
    /// - Parameters:
    ///   - mqttClientOptions: The MQTT broker configuration.
    ///   - delegate: The client delegate that receives transport callbacks.
    ///   - publishHandler: An optional hook observing publication arguments.
    ///   - ingressDeliveryCapacity: Bounds the un-delivered inbound backlog.
    /// - Throws: ``AxolotyError/runtime(code:reason:)`` (code
    ///   ``AxolotyError/RuntimeErrorCode/brokerUnavailable``) if mDNS/Bonjour
    ///   broker discovery is requested but no ``ServiceDiscovery``
    ///   implementation is available on the current platform.
    init(
        mqttClientOptions: MQTTClientOptions,
        delegate: CommunicationClientDelegate,
        publishHandler: PublishHandler? = nil,
        connectHandler: ConnectHandler? = nil,
        ingressDeliveryCapacity: Int = IngressDeliveryQueue.defaultCapacity
    ) throws {
        self.callbackAdapter = MQTTNIOCallbackAdapter(delegate: delegate)
        self.publishHandler = publishHandler
        self.connectHandler = connectHandler

        self.deliveryQueue = IngressDeliveryQueue(capacity: ingressDeliveryCapacity)

        configure(mqttClientOptions)
        callbackAdapter.attach(self)

        try startDiscoveryIfNeeded(mqttClientOptions)
    }

    deinit {
        deliveryQueue.finish()
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
        let callbackAdapter = self.callbackAdapter
        client.addPublishListener(named: "coatyswift") { result in
            callbackAdapter.handlePublish(result)
        }
        client.addCloseListener(named: "coatyswift") { _ in
            callbackAdapter.handleClose()
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

        let connect = connectHandler.map { $0(client) } ?? client.connect(cleanSession: true, will: will)
        connect.whenComplete { [callbackAdapter = self.callbackAdapter] result in
            callbackAdapter.handleConnectionResult(result, attemptId: attemptId, client: client)
        }
    }

    fileprivate func handleConnectionResult(
        _ result: Result<Bool, Swift.Error>,
        attemptId: String,
        client: MQTTClient
    ) {
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
                // A failed connect fires no close listener, so there is no late
                // socket to retire; clear the intentional-disconnect flag.
                if case .failure = result {
                    lock.withLock { lifecycle.isIntentionalDisconnect = false }
                } else {
                    retireLateConnection(client, attemptId)
                }
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

    fileprivate func runReconnect(token: UUID) {
        let mayReconnect = lock.withLock { () -> Bool in
            guard lifecycle.reconnectToken == token,
                  !lifecycle.isIntentionalDisconnect,
                  !lifecycle.isRetiredConnection else {
                return false
            }
            lifecycle.reconnectToken = nil
            lifecycle.reconnectWorkItem = nil
            return true
        }
        if mayReconnect {
            performConnect()
        }
    }

    /// Switches to the next broker candidate (mirrors CocoaMQTTClient's
    /// `connectNext()`), recreating the client instance since mqtt-nio's
    /// `host`/`port` are immutable. Refuses to proceed while an intentional
    /// disconnect is active.
    private func connectNext() {
        let next = lock.withLock { () -> (host: String, port: Int)? in
            guard !lifecycle.isIntentionalDisconnect, !lifecycle.isRetiredConnection else {
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
            log.notice("Error while disconnecting", metadata: [
                "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
            ])
        }
    }

    func publish(_ topic: String, message: String) {
        log.trace("Publishing", metadata: ["topic": .string(topic), "qos": "\(qos)"])
        let client = lock.withLock { lifecycle.client }
        publish(
            to: topic,
            payload: byteBuffer(from: message),
            qos: qos,
            retain: false,
            client: client
        )
    }

    func publish(_ topic: String, message: [UInt8]) {
        log.trace("Publishing", metadata: ["topic": .string(topic), "qos": "\(qos)"])
        let client = lock.withLock { lifecycle.client }
        publish(
            to: topic,
            payload: byteBuffer(from: message),
            qos: qos,
            retain: false,
            client: client
        )
    }

    private func publish(
        to topic: String,
        payload: ByteBuffer,
        qos: MQTTQoS,
        retain: Bool,
        client: MQTTClient?
    ) {
        if let publishHandler {
            publishHandler(qos, retain)
            return
        }

        let log = self.log
        client?.publish(to: topic, payload: payload, qos: qos, retain: retain)
            .whenFailure { error in
                log.warning("Error publishing", metadata: [
                    "topic": .string(topic),
                    "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
                ])
            }
    }

    fileprivate func publicationSnapshot() -> (client: MQTTClient?, qos: MQTTQoS, handler: PublishHandler?) {
        (lock.withLock { lifecycle.client }, qos, publishHandler)
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
        enqueueDelivery {
            await streams.communicationState.sendState(state)
        }
    }

    /// Enqueues one delivery job into the bounded ingress queue, reporting
    /// overload through ``overloadReporter`` when the queue sheds the job
    /// because its buffer is already full.
    private func enqueueDelivery(_ job: @escaping @Sendable () async -> Void) {
        guard !deliveryQueue.enqueue(job) else { return }
        overloadReporter.reportSheddedJob(
            totalDropped: deliveryQueue.droppedCount,
            capacity: deliveryQueue.capacity,
            log: log
        )
    }

    // MARK: - mqtt-nio listener callbacks.

    /// Processes one mqtt-nio PUBLISH at the synchronous-to-async ownership
    /// boundary.
    ///
    /// mqtt-nio owns `info.payload` only for this listener callback. This
    /// method first copies it into `[UInt8]`, then uses `TopicView` only inside
    /// the scoped `String.withUTF8` borrow to make routing decisions and
    /// materialize `ParsedMQTTMessage` metadata as `String`s. Every closure
    /// enqueued in ``deliveryQueue`` captures only owned `Sendable`
    /// values (`RawMQTTMessage`, `IoValueEventSnapshot`, or
    /// `ParsedMQTTMessage`), never `TopicView`, `ByteSlice`, or
    /// `BorrowedMessage`.
    func handlePublish(_ result: Result<MQTTPublishInfo, Swift.Error>) {
        switch result {
        case .success(let info):
            guard info.payload.readableBytes <= HostWirePayloadLimits.maxPayloadSize else {
                log.notice("Dropping incoming MQTT payload above host limit", metadata: [
                    "topic": .string(info.topicName),
                    "payloadLength": .stringConvertible(info.payload.readableBytes),
                    "limit": .stringConvertible(HostWirePayloadLimits.maxPayloadSize),
                ])
                return
            }
            let bytes = [UInt8](info.payload.readableBytesView)
            let rawMessage = RawMQTTMessage(topic: info.topicName, payload: bytes)
            guard let streams = streamsOrWarn() else {
                return
            }
            enqueueDelivery {
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

                // IoValue intentionally keeps its raw payload and bypasses
                // typed event decoding; the host fallback below is for
                // structured event families only.
                if topicView.eventType == .ioValue {
                    self.delegate.didReceiveIoValue(
                        topic: info.topicName,
                        payload: bytes
                    )
                    enqueueDelivery {
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

                let ownedEvent: OwnedWireEvent
                do {
                    if bytes.count > WireBufferConfig.maxPayloadSize {
                        ownedEvent = try HostWireAdapter.decodeEvent(from: bytes, eventType: wireType)
                    } else {
                        ownedEvent = try bytes.withUnsafeBufferPointer { payloadBuffer in
                            guard let payloadBase = payloadBuffer.baseAddress else {
                                throw WireDecodeError(.unexpectedEndOfInput)
                            }
                            let message = BorrowedMessage(
                                topicBytes: base,
                                topicLength: topicBuf.count,
                                payloadBytes: payloadBase,
                                payloadLength: payloadBuffer.count
                            )
                            return try BorrowedWireEvent(message: message).owned()
                        }
                    }
                } catch {
                    let wrapped = (error as? AxolotyError) ?? AxolotyError.decodingFailure(
                        type: wireType.rawValue,
                        reason: ErrorKit.userFriendlyMessage(for: error),
                        payload: String(bytes: bytes, encoding: .utf8)
                    )
                    log.notice("Dropping malformed incoming event", metadata: [
                        "topic": .string(info.topicName),
                        "eventType": .string(wireType.rawValue),
                        "error": .string(ErrorKit.errorChainDescription(for: wrapped)),
                    ])
                    return
                }
                let parsed = ParsedMQTTMessage(topicView: topicView, event: ownedEvent, payload: bytes)
                enqueueDelivery {
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

    /// Called whenever the underlying connection closes, whether due to an
    /// explicit `disconnect()`, a dropped connection, or a failed connect
    /// attempt. Mirrors CocoaMQTTClient's `mqttDidDisconnect` delegate method:
    /// updates communication state to `.offline`, then falls back to the next
    /// broker candidate if any are queued, or lets `autoReconnect` retry the
    /// same host after `autoReconnectTimeInterval` seconds.
    fileprivate func handleClose() {
        updateCommunicationState(.offline)

        // Only the close listener clears the intentional-disconnect flag, so a
        // reconnect path racing with `disconnect()` still observes it. Read the
        // fallback decision under the same lock.
        let (shouldReconnect, hasCandidates) = lock.withLock { () -> (Bool, Bool) in
            if lifecycle.isIntentionalDisconnect || lifecycle.isRetiredConnection {
                lifecycle.isIntentionalDisconnect = false
                lifecycle.isRetiredConnection = false
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

    /// Retires a connection attempt that completed *after* an explicit
    /// `disconnect()`, so a later start can connect normally. Lifts the
    /// intentional-disconnect flag (a subsequent start must not stay blocked),
    /// marks the connection retired so ``handleClose()`` treats its close as
    /// intentional instead of a dropped connection, and closes the late socket.
    private func retireLateConnection(_ client: MQTTClient, _ attemptId: String) {
        lock.withLock {
            lifecycle.isIntentionalDisconnect = false
            lifecycle.isRetiredConnection = true
        }
        log.notice("Abandoning connection result; attempt superseded by disconnect", metadata: [
            "correlationId": .string(attemptId),
            "broker": "\(client.host):\(client.port)",
        ])
        let log = self.log
        client.disconnect().whenFailure { error in
            log.notice("Error closing late connection established after disconnect", metadata: [
                "correlationId": .string(attemptId),
                "broker": "\(client.host):\(client.port)",
                "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
            ])
        }
    }

    func scheduleReconnect() {
        let delaySeconds = max(mqttClientOptions.autoReconnectTimeInterval, 0)
        let token = UUID()
        let callbackAdapter = self.callbackAdapter
        let workItem = DispatchWorkItem { [callbackAdapter] in
            // Re-check after the delay: a disconnect or replacement that raced
            // with queue cancellation retires this callback's token, so no
            // reconnect fires after explicit teardown.
            callbackAdapter.reconnect(token: token)
        }
        // Retain the work item so disconnect()/replaceClient()/deinit can
        // cancel it, cancelling any previously scheduled reconnect first. The
        // intentional-disconnect check and installation share one critical
        // section so disconnect cannot miss a just-created reconnect.
        let scheduling = lock.withLock { () -> (shouldSchedule: Bool, previous: DispatchWorkItem?) in
            guard !lifecycle.isIntentionalDisconnect, !lifecycle.isRetiredConnection else {
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

extension MQTTNIOClient {

    @MainActor
    func publishAndWait(_ topic: String, message: [UInt8]) async throws {
        let snapshot = publicationSnapshot()
        if let handler = snapshot.handler {
            handler(snapshot.qos, false)
            return
        }
        guard let client = snapshot.client else {
            throw AxolotyError.runtime(code: .notStarted, reason: "Cannot publish before the MQTT client is initialized.")
        }

        do {
            try await client.publish(
                to: topic,
                payload: byteBuffer(from: message),
                qos: snapshot.qos,
                retain: false
            ).get()
        } catch {
            throw AxolotyError.caught(error)
        }
    }
}

/// Owns the mutable callback-facing references for ``MQTTNIOClient``.
///
/// mqtt-nio invokes listeners and future completions from contexts that are
/// independent of the caller that created the client. The adapter is the only
/// object captured by those callbacks; its lock protects delegate, stream, and
/// client access while the client remains a non-Sendable implementation detail.
private final class MQTTNIOCallbackAdapter: @unchecked Sendable {
    private let lock = NIOLock()
    private weak var client: MQTTNIOClient?
    private var _delegate: CommunicationClientDelegate
    private var _streams: CommunicationStreams?

    var delegate: CommunicationClientDelegate {
        lock.withLock { _delegate }
    }

    var streams: CommunicationStreams? {
        lock.withLock { _streams }
    }

    init(delegate: CommunicationClientDelegate) {
        _delegate = delegate
    }

    func attach(_ client: MQTTNIOClient) {
        lock.withLock { self.client = client }
    }

    func setDelegate(_ delegate: CommunicationClientDelegate) {
        lock.withLock { _delegate = delegate }
    }

    func setStreams(_ streams: CommunicationStreams) {
        lock.withLock { _streams = streams }
    }

    func handlePublish(_ result: Result<MQTTPublishInfo, Swift.Error>) {
        lock.withLock { client }?.handlePublish(result)
    }

    func handleClose() {
        lock.withLock { client }?.handleClose()
    }

    func handleConnectionResult(
        _ result: Result<Bool, Swift.Error>,
        attemptId: String,
        client: MQTTClient
    ) {
        lock.withLock { self.client }?.handleConnectionResult(result, attemptId: attemptId, client: client)
    }

    func reconnect(token: UUID) {
        lock.withLock { client }?.runReconnect(token: token)
    }
}

/// Mutable connection-lifecycle state guarded by ``MQTTNIOClient``'s ``lock``.
/// Grouped into one box so every read/write of the client reference, connection
/// flags, and reconnect work item is a single locked critical section, never
/// split across a suspension point.
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

    /// Set while a connection that completed after an explicit `disconnect()`
    /// is being retired; its close is treated as intentional (no reconnect).
    var isRetiredConnection = false

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
