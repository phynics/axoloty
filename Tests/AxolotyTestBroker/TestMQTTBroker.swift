// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// An in-process MQTT 3.1.1 broker for tests.
///
/// It exists so broker-backed checks need no container runtime, no Mosquitto,
/// and no fixed port. It binds an ephemeral port and reports it, keeps the
/// subset of MQTT 3.1.1 that Axoloty exercises, and exposes an inspection
/// surface so reconnect and last-will paths are asserted from observed state
/// rather than from timing.
///
/// This is verification infrastructure. It is a product so test targets can
/// depend on it, and no shipped product may.
public final class TestMQTTBroker: Sendable {
    public struct Configuration: Sendable {
        public var host: String
        public var port: Int

        public init(host: String = "127.0.0.1", port: Int = 0) {
            self.host = host
            self.port = port
        }
    }

    private let configuration: Configuration
    private let group: MultiThreadedEventLoopGroup
    private let state = NIOLockedValueBox(BrokerState())
    private let channel = NIOLockedValueBox<Channel?>(nil)

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Binds the listener and returns the port it bound.
    ///
    /// With the default port `0` the kernel assigns an ephemeral port, so two
    /// brokers never contend for `1883`.
    @discardableResult
    public func start() throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(TestMQTTBrokerError.stopped)
                }
                let id = self.allocateConnectionID()
                self.registerConnection(id: id, channel: channel)
                return channel.pipeline.addHandler(BrokerConnectionHandler(broker: self, connectionID: id))
            }
        let bound = try bootstrap.bind(host: configuration.host, port: configuration.port).wait()
        channel.withLockedValue { $0 = bound }
        return bound.localAddress?.port ?? configuration.port
    }

    /// Closes the listener and releases the event loop group.
    public func stop() {
        if let bound = channel.withLockedValue({ $0 }) {
            try? bound.close().wait()
        }
        channel.withLockedValue { $0 = nil }
        try? group.syncShutdownGracefully()
    }

    /// The bound port, or `0` before ``start()``.
    public var port: Int {
        channel.withLockedValue { $0?.localAddress?.port } ?? 0
    }

    public var host: String { configuration.host }

    // MARK: - Inspection

    public func connections() -> [BrokerConnection] {
        state.withLockedValue { $0.connections.values.map(\.snapshot).sorted { $0.id < $1.id } }
    }

    public func subscriptions() -> [BrokerSubscription] {
        state.withLockedValue { current in
            current.sessions.flatMap { clientID, session in
                session.subscriptions.map { BrokerSubscription(clientID: clientID, filter: $0.key, qos: $0.value) }
            }
            .sorted { ($0.clientID, $0.filter) < ($1.clientID, $1.filter) }
        }
    }

    public func retainedMessages() -> [BrokerRetainedMessage] {
        state.withLockedValue { current in
            current.retained.map { BrokerRetainedMessage(topic: $0.key, payload: $0.value.payload, qos: $0.value.qos) }
                .sorted { $0.topic < $1.topic }
        }
    }

    public func publishedFrames() -> [BrokerPublishedFrame] {
        state.withLockedValue { $0.published }
    }

    public func clearInspection() {
        state.withLockedValue { current in
            current.published.removeAll()
        }
    }

    /// Closes a live connection without a `DISCONNECT`.
    ///
    /// A client that registered a will therefore has it published, which is
    /// how the last-will path is exercised without killing a real network.
    public func injectDisconnect(connectionID: UInt64) throws {
        let target = state.withLockedValue { $0.connections[connectionID]?.channel }
        guard let target else { throw TestMQTTBrokerError.unknownConnection(connectionID) }
        try target.close().wait()
    }

    // MARK: - Connection lifecycle

    func allocateConnectionID() -> UInt64 {
        state.withLockedValue { current in
            defer { current.nextConnectionID += 1 }
            return current.nextConnectionID
        }
    }

    func registerConnection(id: UInt64, channel: Channel) {
        state.withLockedValue { current in
            current.connections[id] = ConnectionRecord(id: id, channel: channel, clientID: nil, active: true)
        }
    }

    /// Records the `CONNECT` and returns whether a stored session was resumed.
    func connectionAuthenticated(
        id: UInt64,
        clientID: String,
        will: MQTTWill?,
        cleanSession: Bool
    ) -> Bool {
        state.withLockedValue { current in
            current.connections[id]?.clientID = clientID
            current.connections[id]?.will = will
            current.connections[id]?.cleanSession = cleanSession
            if cleanSession {
                current.sessions.removeValue(forKey: clientID)
                return false
            }
            return current.sessions[clientID] != nil
        }
    }

    /// Applies a `SUBSCRIBE`, returning the granted QoS for each filter.
    func addSubscriptions(clientID: String, requests: [MQTTSubscriptionRequest]) -> [UInt8] {
        state.withLockedValue { current in
            var session = current.sessions[clientID] ?? SessionRecord(clientID: clientID)
            var granted: [UInt8] = []
            for request in requests {
                guard MQTTTopicMatcher.isValidFilter(request.filter) else {
                    granted.append(0x80)
                    continue
                }
                let qos = min(request.qos, 1)
                session.subscriptions[request.filter] = qos
                granted.append(qos)
            }
            current.sessions[clientID] = session
            return granted
        }
    }

    /// Allocates the next outbound packet identifier for a session.
    func nextOutboundPacketID(clientID: String) -> UInt16 {
        state.withLockedValue { current in
            var session = current.sessions[clientID] ?? SessionRecord(clientID: clientID)
            let id = session.nextPacketID
            session.nextPacketID = session.nextPacketID == UInt16.max ? 1 : session.nextPacketID + 1
            current.sessions[clientID] = session
            return id
        }
    }

    func removeSubscriptions(clientID: String, filters: [String]) {
        state.withLockedValue { current in
            guard var session = current.sessions[clientID] else { return }
            for filter in filters {
                session.subscriptions.removeValue(forKey: filter)
            }
            current.sessions[clientID] = session
        }
    }

    func retainedMessages(matching filters: [String]) -> [BrokerRetainedMessage] {
        state.withLockedValue { current in
            current.retained
                .filter { topic, _ in filters.contains { MQTTTopicMatcher.matches(filter: $0, topic: topic) } }
                .map { BrokerRetainedMessage(topic: $0.key, payload: $0.value.payload, qos: $0.value.qos) }
                .sorted { $0.topic < $1.topic }
        }
    }

    /// The publications the broker has written to each subscriber.
    public func deliveries() -> [BrokerDelivery] {
        state.withLockedValue { $0.deliveries }
    }

    /// Handles an inbound `PUBLISH`: records it, applies retention, and routes
    /// it to every active subscription that matches.
    func handleInboundPublish(_ packet: MQTTPublishPacket) {
        state.withLockedValue { current in
            current.published.append(BrokerPublishedFrame(
                topic: packet.topic,
                payload: packet.payload,
                qos: packet.qos,
                retained: packet.retain
            ))
            if packet.retain {
                if packet.payload.isEmpty {
                    current.retained.removeValue(forKey: packet.topic)
                } else {
                    current.retained[packet.topic] = RetainedMessage(payload: packet.payload, qos: packet.qos)
                }
            }
            route(packet, in: &current)
        }
    }

    /// Routes a `PUBLISH` to each matching active session.
    private func route(_ packet: MQTTPublishPacket, in current: inout BrokerState) {
        for (clientID, session) in current.sessions {
            let deliveryQoS = session.subscriptions.reduce(into: UInt8(0)) { best, entry in
                if MQTTTopicMatcher.matches(filter: entry.key, topic: packet.topic) {
                    best = max(best, min(entry.value, packet.qos))
                }
            }
            guard session.subscriptions.contains(where: {
                MQTTTopicMatcher.matches(filter: $0.key, topic: packet.topic)
            }) else { continue }
            guard let connectionID = current.connections.first(where: {
                $0.value.clientID == clientID && $0.value.active
            })?.key,
                let channel = current.connections[connectionID]?.channel else { continue }
            var session = session
            let packetID: UInt16?
            if deliveryQoS > 0 {
                packetID = session.nextPacketID
                session.nextPacketID = session.nextPacketID == UInt16.max ? 1 : session.nextPacketID + 1
                current.sessions[clientID] = session
            } else {
                packetID = nil
            }
            let frame = MQTTPacketEncoder.publish(
                topic: packet.topic,
                payload: packet.payload,
                qos: deliveryQoS,
                retain: false,
                duplicate: false,
                packetID: packetID
            )
            current.deliveries.append(BrokerDelivery(clientID: clientID, topic: packet.topic, qos: deliveryQoS))
            channel.writeAndFlush(frame, promise: nil)
        }
    }

    /// Handles a closed connection, publishing the will when the close was not
    /// a clean `DISCONNECT`.
    func connectionClosed(id: UInt64, cleanly: Bool) {
        state.withLockedValue { current in
            guard let record = current.connections[id], record.active else { return }
            current.connections[id]?.active = false
            let clientID = record.clientID
            let cleanSession = current.connections[id]?.cleanSession ?? true
            defer {
                current.connections.removeValue(forKey: id)
                if cleanSession, let clientID {
                    current.sessions.removeValue(forKey: clientID)
                }
            }
            guard !cleanly, let will = record.will else { return }
            let willPacket = MQTTPublishPacket(
                topic: will.topic,
                payload: will.message,
                qos: will.qos,
                retain: will.retain,
                duplicate: false,
                packetID: will.qos > 0 ? 1 : nil
            )
            current.published.append(BrokerPublishedFrame(
                topic: willPacket.topic,
                payload: willPacket.payload,
                qos: willPacket.qos,
                retained: willPacket.retain
            ))
            if willPacket.retain {
                if willPacket.payload.isEmpty {
                    current.retained.removeValue(forKey: willPacket.topic)
                } else {
                    current.retained[willPacket.topic] = RetainedMessage(payload: willPacket.payload, qos: willPacket.qos)
                }
            }
            route(willPacket, in: &current)
        }
    }
}

/// A live or recently closed client connection.
public struct BrokerConnection: Sendable, Equatable {
    public let id: UInt64
    public let clientID: String?
    public let active: Bool
}

/// One subscription held by a session.
public struct BrokerSubscription: Sendable, Equatable {
    public let clientID: String
    public let filter: String
    public let qos: UInt8
}

/// A retained publication the broker currently holds.
public struct BrokerRetainedMessage: Sendable, Equatable {
    public let topic: String
    public let payload: [UInt8]
    public let qos: UInt8
}

/// A publication the broker observed, whether from a client or a will.
public struct BrokerPublishedFrame: Sendable, Equatable {
    public let topic: String
    public let payload: [UInt8]
    public let qos: UInt8
    public let retained: Bool
}

/// A publication the broker wrote to one subscriber.
public struct BrokerDelivery: Sendable, Equatable {
    public let clientID: String
    public let topic: String
    public let qos: UInt8
}

public enum TestMQTTBrokerError: Error, Sendable, Equatable {
    case stopped
    case unknownConnection(UInt64)
}

private struct ConnectionRecord: Sendable {
    var id: UInt64
    var channel: Channel
    var clientID: String?
    var will: MQTTWill?
    var cleanSession: Bool = true
    var active: Bool

    var snapshot: BrokerConnection {
        BrokerConnection(id: id, clientID: clientID, active: active)
    }
}

private struct SessionRecord: Sendable {
    var clientID: String
    var subscriptions: [String: UInt8] = [:]
    var nextPacketID: UInt16 = 1
}

private struct RetainedMessage: Sendable {
    var payload: [UInt8]
    var qos: UInt8
}

private struct BrokerState: Sendable {
    var nextConnectionID: UInt64 = 1
    var connections: [UInt64: ConnectionRecord] = [:]
    var sessions: [String: SessionRecord] = [:]
    var retained: [String: RetainedMessage] = [:]
    var published: [BrokerPublishedFrame] = []
    var deliveries: [BrokerDelivery] = []
}
