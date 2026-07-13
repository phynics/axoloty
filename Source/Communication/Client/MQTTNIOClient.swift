// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  MQTTNIOClient.swift
//  CoatySwift
//
//

import Foundation
import Logging
import MQTTNIO
import NIO
import RxSwift

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
/// exact same `CommunicationClient` contract (Rx-based observable surface) so
/// that `CommunicationManager` and every other consumer is unaffected; only the
/// underlying MQTT transport changes.
///
/// - Note: mqtt-nio's `MQTTClient` exposes an `EventLoopFuture`-based API with a
///   named-listener registration model for incoming PUBLISH messages (not
///   async/await, and not delegate-based in the `NSObjectProtocol` sense used by
///   CocoaMQTT) — see `addPublishListener(named:_:)`/`addCloseListener(named:_:)`.
///   Those listener callbacks are plain synchronous closures, so they bridge
///   directly into the Rx `PublishSubject`/`BehaviorSubject` surface via
///   `.onNext(...)` without needing a `Task`/`AsyncSequence` bridge.
internal class MQTTNIOClient: CommunicationClient {

    private let log = LogManager.log

    // MARK: - Protocol fields.

    var rawMQTTMessages = PublishSubject<(String, [UInt8])>()
    var ioValueMessages = PublishSubject<(String, [UInt8])>()
    var messages = PublishSubject<(CommunicationTopic, String)>()
    var communicationState = BehaviorSubject(value: CommunicationState.offline)
    var delegate: Startable
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

    init(mqttClientOptions: MQTTClientOptions, delegate: Startable) {
        self.delegate = delegate
        configure(mqttClientOptions)

        // `try!` matches the existing fail-fast convention used elsewhere
        // during initialization (see `CommunicationManager.init`).
        try! startDiscoveryIfNeeded(mqttClientOptions)
    }

    deinit {
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
    /// - Throws: `CoatySwiftError.RuntimeError` if discovery is requested
    ///   but no `ServiceDiscovery` implementation is available on the
    ///   current platform (e.g. non-Apple platforms). In that case,
    ///   configure an explicit broker `host`/`port` instead.
    private func startDiscoveryIfNeeded(_ mqttClientOptions: MQTTClientOptions) throws {
        guard mqttClientOptions.shouldTryMDNSDiscovery else {
            return
        }

        #if canImport(Darwin)
        discovery = BonjourResolver()
        discovery?.delegate = self
        discovery?.startDiscovery()
        #else
        throw CoatySwiftError.RuntimeError(
            "mDNS/Bonjour broker discovery (shouldTryMDNSDiscovery) was requested, but no " +
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
                self.log.debug("Connection error: \(error)")
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
            self?.log.debug("Error while disconnecting: \(error)")
        }
    }

    func publish(_ topic: String, message: String) {
        client?.publish(to: topic, payload: byteBuffer(from: message), qos: qos, retain: false)
            .whenFailure { [weak self] error in
                self?.log.debug("Error publishing to \(topic): \(error)")
            }
    }

    func publish(_ topic: String, message: [UInt8]) {
        // NOTE: preserves a pre-existing quirk of the former CocoaMQTTClient:
        // this overload always publishes at QoS 0, unretained, regardless of
        // `mqttClientOptions.qos`. Not changed here; flagged, not silently
        // "fixed".
        client?.publish(to: topic, payload: byteBuffer(from: message), qos: .atMostOnce, retain: false)
            .whenFailure { [weak self] error in
                self?.log.debug("Error publishing to \(topic): \(error)")
            }
    }

    func subscribe(_ topic: String) {
        client?.subscribe(to: [MQTTSubscribeInfo(topicFilter: topic, qos: qos)]).whenComplete { [weak self] result in
            switch result {
            case .success:
                self?.log.debug("Subscribed to topic \(topic).")
            case .failure(let error):
                self?.log.debug("Error subscribing to topic \(topic): \(error)")
            }
        }
    }

    func unsubscribe(_ topic: String) {
        client?.unsubscribe(from: [topic]).whenComplete { [weak self] result in
            switch result {
            case .success:
                self?.log.debug("Unsubscribed from topic \(topic).")
            case .failure(let error):
                self?.log.debug("Error unsubscribing from topic \(topic): \(error)")
            }
        }
    }

    // MARK: - State management methods.

    func updateCommunicationState(_ state: CommunicationState) {
        communicationState.onNext(state)
    }

    // MARK: - mqtt-nio listener callbacks.

    private func handlePublish(_ result: Result<MQTTPublishInfo, Swift.Error>) {
        switch result {
        case .success(let info):
            let bytes = [UInt8](info.payload.readableBytesView)

            if CommunicationTopic.isRawTopic(topic: info.topicName) {
                rawMQTTMessages.onNext((info.topicName, bytes))
                return
            }

            do {
                let topic = try CommunicationTopic(info.topicName)
                if topic.eventType == .IoValue {
                    ioValueMessages.onNext((info.topicName, bytes))
                } else if let payloadString = String(bytes: bytes, encoding: .utf8) {
                    messages.onNext((topic, payloadString))
                }
            } catch {
                log.debug("Ignoring incoming event on \(info.topicName): \(error)")
            }
        case .failure(let error):
            log.debug("Error receiving published message: \(error)")
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
