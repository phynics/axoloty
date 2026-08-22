// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@preconcurrency import MQTTNIO
import NIO
import NIOConcurrencyHelpers

#if canImport(Network)
import Network
import NIOTransportServices
#else
import NIOSSL
#endif

/// The transport-only callback surface used by ``MQTTBinding``.
protocol RuntimeMQTTClientDelegate: AnyObject, Sendable {
    func runtimeMQTTClientDidBecomeOnline()
    func runtimeMQTTClientDidBecomeOffline()
    func runtimeMQTTClientDidReceive(topic: String, payload: [UInt8])
    func runtimeMQTTClientDidFail(_ error: Error)
}

/// A bounded MQTT-NIO adapter for the structured runtime.
///
/// This type owns only the broker socket and copies publish data at the
/// synchronous MQTT callback boundary. Protocol parsing and lifecycle policy
/// remain in ``AxolotyRuntime``.
final class RuntimeMQTTClient: @unchecked Sendable {
    private let lock = NIOLock()
    private let delegate: RuntimeMQTTClientDelegate
    private let qos: MQTTQoS = .atMostOnce

#if canImport(Network)
    private let eventLoopGroup: EventLoopGroup = NIOTSEventLoopGroup(loopCount: 1)
#else
    private let eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
#endif

    private let client: MQTTClient
    private var intentionalDisconnect = false

    init(configuration: MQTTBindingConfiguration, delegate: RuntimeMQTTClientDelegate) throws {
        self.delegate = delegate
        let mqttConfiguration = MQTTClient.Configuration(
            keepAliveInterval: .seconds(30),
            userName: configuration.username,
            password: configuration.password,
            useSSL: configuration.usesTLS,
            tlsConfiguration: Self.tlsConfiguration(usesTLS: configuration.usesTLS)
        )
        self.client = MQTTClient(
            host: configuration.host,
            port: Int(configuration.port),
            identifier: "axoloty-runtime-\(UUID().uuidString)",
            eventLoopGroupProvider: .shared(eventLoopGroup),
            logger: nil,
            configuration: mqttConfiguration
        )
        client.addPublishListener(named: "axoloty-runtime") { [weak self] result in
            self?.handlePublish(result)
        }
        client.addCloseListener(named: "axoloty-runtime") { [weak self] _ in
            self?.handleClose()
        }
    }

    deinit {
        lock.withLock { intentionalDisconnect = true }
        client.shutdown(queue: .global()) { _ in }
        eventLoopGroup.shutdownGracefully { _ in }
    }

    func connect() {
        lock.withLock { intentionalDisconnect = false }
        client.connect(cleanSession: true, will: nil).whenComplete { [weak self] result in
            switch result {
            case .success:
                self?.delegate.runtimeMQTTClientDidBecomeOnline()
            case let .failure(error):
                self?.delegate.runtimeMQTTClientDidFail(error)
            }
        }
    }

    func disconnect() {
        lock.withLock { intentionalDisconnect = true }
        client.disconnect().whenFailure { [weak self] error in
            self?.delegate.runtimeMQTTClientDidFail(error)
        }
    }

    func publish(topic: String, payload: [UInt8]) {
        var buffer = ByteBufferAllocator().buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        client.publish(to: topic, payload: buffer, qos: qos, retain: false).whenFailure { [weak self] error in
            self?.delegate.runtimeMQTTClientDidFail(error)
        }
    }

    @MainActor
    func subscribe(_ topic: String) async throws {
        do {
            _ = try await client.subscribe(
                to: [MQTTSubscribeInfo(topicFilter: topic, qos: qos)]
            ).get()
        } catch {
            throw AxolotyError.network(error: error, reason: "MQTT subscription failed")
        }
    }

    @MainActor
    func unsubscribe(_ topic: String) async throws {
        do {
            _ = try await client.unsubscribe(from: [topic]).get()
        } catch {
            throw AxolotyError.network(error: error, reason: "MQTT unsubscription failed")
        }
    }

    private func handlePublish(_ result: Result<MQTTPublishInfo, Error>) {
        switch result {
        case let .success(info):
            let payload = Array(info.payload.readableBytesView)
            delegate.runtimeMQTTClientDidReceive(topic: info.topicName, payload: payload)
        case let .failure(error):
            delegate.runtimeMQTTClientDidFail(error)
        }
    }

    private func handleClose() {
        guard !lock.withLock({ intentionalDisconnect }) else { return }
        delegate.runtimeMQTTClientDidBecomeOffline()
    }

    private static func tlsConfiguration(usesTLS: Bool) -> MQTTClient.TLSConfigurationType? {
        guard usesTLS else { return nil }
#if canImport(Network)
        return .ts(TSTLSConfiguration(certificateVerification: .fullVerification))
#else
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .fullVerification
        return .niossl(configuration)
#endif
    }
}
