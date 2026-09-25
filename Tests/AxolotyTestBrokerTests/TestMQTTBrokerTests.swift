// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyTestBroker
import MQTTNIO
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix
import Testing

/// Drives an ``TestMQTTBroker`` through a real MQTTNIO client over a loopback
/// socket. The point is to prove the broker satisfies the wire behaviour the
/// Axoloty transport depends on, not to re-test MQTTNIO.
@Suite("TestMQTTBroker")
struct TestMQTTBrokerTests {
    @Test("binds an ephemeral port and two brokers never share one")
    func ephemeralPort() throws {
        let first = TestMQTTBroker()
        let second = TestMQTTBroker()
        defer { first.stop(); second.stop() }
        let firstPort = try first.start()
        let secondPort = try second.start()
        #expect(firstPort > 0)
        #expect(secondPort > 0)
        #expect(firstPort != secondPort)
    }

    @Test("records a connection when a client connects")
    func connectIsRecorded() async throws {
        let broker = TestMQTTBroker()
        let port = try broker.start()
        defer { broker.stop() }
        let client = try BrokerClient(port: port, identifier: "connect-client")
        defer { Task { await client.shutdown() } }
        try await client.connect()

        try await waitFor("connection registration") {
            broker.connections().contains { $0.clientID == "connect-client" && $0.active }
        }
    }

    @Test("delivers a QoS 0 publication to a matching subscriber")
    func qos0Delivery() async throws {
        let broker = TestMQTTBroker()
        let port = try broker.start()
        defer { broker.stop() }
        let subscriber = try BrokerClient(port: port, identifier: "sub-qos0")
        let publisher = try BrokerClient(port: port, identifier: "pub-qos0")
        defer { Task { await subscriber.shutdown(); await publisher.shutdown() } }
        try await subscriber.connect()
        try await publisher.connect()
        try await subscriber.subscribe("axoloty/test/qos0")

        try await publisher.publish("axoloty/test/qos0", "hello", qos: .atMostOnce)

        try await waitFor("QoS 0 delivery") {
            subscriber.collector.contains(topic: "axoloty/test/qos0", payload: "hello")
        }
    }

    @Test("delivers a QoS 1 publication and acknowledges it")
    func qos1Delivery() async throws {
        let broker = TestMQTTBroker()
        let port = try broker.start()
        defer { broker.stop() }
        let subscriber = try BrokerClient(port: port, identifier: "sub-qos1")
        let publisher = try BrokerClient(port: port, identifier: "pub-qos1")
        defer { Task { await subscriber.shutdown(); await publisher.shutdown() } }
        try await subscriber.connect()
        try await publisher.connect()
        try await subscriber.subscribe("axoloty/test/qos1", qos: .atLeastOnce)

        try await publisher.publish("axoloty/test/qos1", "acknowledged", qos: .atLeastOnce)

        try await waitFor("QoS 1 delivery") {
            subscriber.collector.contains(topic: "axoloty/test/qos1", payload: "acknowledged")
        }
    }

    @Test("delivers a retained publication to a later subscriber")
    func retainedDelivery() async throws {
        let broker = TestMQTTBroker()
        let port = try broker.start()
        defer { broker.stop() }
        let publisher = try BrokerClient(port: port, identifier: "pub-retain")
        defer { Task { await publisher.shutdown() } }
        try await publisher.connect()
        try await publisher.publish("axoloty/test/retained", "kept", qos: .atMostOnce, retain: true)

        try await waitFor("retained storage") {
            broker.retainedMessages().contains { $0.topic == "axoloty/test/retained" }
        }

        let subscriber = try BrokerClient(port: port, identifier: "sub-retain")
        defer { Task { await subscriber.shutdown() } }
        try await subscriber.connect()
        try await subscriber.subscribe("axoloty/test/retained")

        try await waitFor("retained delivery") {
            subscriber.collector.contains(topic: "axoloty/test/retained", payload: "kept")
        }
    }

    @Test("stops delivering after an unsubscribe")
    func unsubscribeStopsDelivery() async throws {
        let broker = TestMQTTBroker()
        let port = try broker.start()
        defer { broker.stop() }
        let subscriber = try BrokerClient(port: port, identifier: "sub-unsub")
        let publisher = try BrokerClient(port: port, identifier: "pub-unsub")
        defer { Task { await subscriber.shutdown(); await publisher.shutdown() } }
        try await subscriber.connect()
        try await publisher.connect()
        try await subscriber.subscribe("axoloty/test/unsub")
        try await subscriber.unsubscribe("axoloty/test/unsub")

        try await publisher.publish("axoloty/test/unsub", "ignored", qos: .atMostOnce)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!subscriber.collector.contains(topic: "axoloty/test/unsub", payload: "ignored"))
    }

    @Test("publishes the will when a connection drops without DISCONNECT")
    func willIsPublished() async throws {
        let broker = TestMQTTBroker()
        let port = try broker.start()
        defer { broker.stop() }
        let observer = try BrokerClient(port: port, identifier: "will-observer")
        let doomed = try BrokerClient(port: port, identifier: "will-client")
        defer { Task { await observer.shutdown(); await doomed.shutdown() } }
        try await observer.connect()
        try await observer.subscribe("axoloty/test/will")
        try await doomed.connect(will: ("axoloty/test/will", "gone"))

        try await waitFor("will connection registration") {
            broker.connections().contains { $0.clientID == "will-client" && $0.active }
        }
        let connectionID = try #require(
            broker.connections().first { $0.clientID == "will-client" }?.id
        )
        try broker.injectDisconnect(connectionID: connectionID)

        try await waitFor("will publication") {
            observer.collector.contains(topic: "axoloty/test/will", payload: "gone")
        }
    }

    @Test("keeps subscriptions across a reconnect with a persistent session")
    func persistentSessionKeepsSubscriptions() async throws {
        let broker = TestMQTTBroker()
        let port = try broker.start()
        defer { broker.stop() }
        let publisher = try BrokerClient(port: port, identifier: "pub-persistent")
        let subscriber = try BrokerClient(port: port, identifier: "sub-persistent")
        defer { Task { await publisher.shutdown(); await subscriber.shutdown() } }
        try await publisher.connect()
        try await subscriber.connect(cleanSession: false)
        try await subscriber.subscribe("axoloty/test/persistent")
        await subscriber.disconnect()
        try await subscriber.connect(cleanSession: false)

        try await publisher.publish("axoloty/test/persistent", "resumed", qos: .atMostOnce)
        try await waitFor("delivery on a resumed session") {
            subscriber.collector.contains(topic: "axoloty/test/persistent", payload: "resumed")
        }
    }
}

/// An MQTTNIO client plus a lock-protected record of what it received.
private final class BrokerClient: @unchecked Sendable {
    let collector = MessageCollector()
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let client: MQTTClient

    init(port: Int, identifier: String) throws {
        client = MQTTClient(
            host: "127.0.0.1",
            port: port,
            identifier: identifier,
            eventLoopGroupProvider: .shared(group),
            logger: nil,
            configuration: MQTTClient.Configuration(
                keepAliveInterval: .seconds(30),
                timeout: .seconds(5)
            )
        )
        let collector = collector
        client.addPublishListener(named: "test-\(identifier)") { result in
            if case let .success(info) = result {
                collector.append(info)
            }
        }
    }

    func connect(cleanSession: Bool = true, will: (topic: String, payload: String)? = nil) async throws {
        let mqttWill: (topicName: String, payload: ByteBuffer, qos: MQTTQoS, retain: Bool)? = will.map {
            (topicName: $0.topic, payload: ByteBuffer(string: $0.payload), qos: .atMostOnce, retain: false)
        }
        _ = try await client.connect(cleanSession: cleanSession, will: mqttWill).get()
    }

    func disconnect() async {
        _ = try? await client.disconnect().get()
    }

    func subscribe(_ filter: String, qos: MQTTQoS = .atMostOnce) async throws {
        _ = try await client.subscribe(to: [MQTTSubscribeInfo(topicFilter: filter, qos: qos)]).get()
    }

    func unsubscribe(_ filter: String) async throws {
        _ = try await client.unsubscribe(from: [filter]).get()
    }

    func publish(_ topic: String, _ payload: String, qos: MQTTQoS, retain: Bool = false) async throws {
        try await client.publish(to: topic, payload: ByteBuffer(string: payload), qos: qos, retain: retain).get()
    }

    func shutdown() async {
        await withCheckedContinuation { continuation in
            client.shutdown(queue: .global()) { _ in continuation.resume() }
        }
        try? await group.shutdownGracefully()
    }
}

private final class MessageCollector: @unchecked Sendable {
    private let lock = NIOLock()
    private var messages: [(topic: String, payload: String)] = []

    func append(_ info: MQTTPublishInfo) {
        let payload = info.payload.getString(at: info.payload.readerIndex, length: info.payload.readableBytes) ?? ""
        lock.withLock { messages.append((info.topicName, payload)) }
    }

    func contains(topic: String, payload: String) -> Bool {
        lock.withLock { messages.contains { $0.topic == topic && $0.payload == payload } }
    }
}

/// Polls `condition` until it holds or the deadline elapses.
private func waitFor(
    _ description: String,
    timeout: Duration = .seconds(5),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await !condition() {
        if clock.now >= deadline {
            Issue.record("timed out waiting for \(description)")
            throw WaitTimeout(awaited: description)
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private struct WaitTimeout: Error, CustomStringConvertible {
    let awaited: String
    var description: String { "timed out waiting for \(awaited)" }
}
