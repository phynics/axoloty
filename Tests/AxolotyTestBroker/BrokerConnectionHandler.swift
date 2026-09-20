// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import NIOCore

/// Per-connection MQTT 3.1.1 state machine.
///
/// The handler is confined to one event loop, so its mutable fields need no
/// lock; `@unchecked Sendable` records that the confinement is the guarantee.
final class BrokerConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let broker: TestMQTTBroker
    private let connectionID: UInt64
    private var buffer = ByteBuffer()
    private var clientID: String?
    private var will: MQTTWill?
    private var cleanSession = true
    private var cleanDisconnect = false

    init(broker: TestMQTTBroker, connectionID: UInt64) {
        self.broker = broker
        self.connectionID = connectionID
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inbound = unwrapInboundIn(data)
        buffer.writeBuffer(&inbound)
        while let (packet, consumed) = MQTTPacketDecoder.decodeFrame(from: buffer) {
            buffer.moveReaderIndex(forwardBy: consumed)
            handle(packet, channel: context.channel)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        broker.connectionClosed(id: connectionID, cleanly: cleanDisconnect)
    }

    private func handle(_ packet: MQTTDecodedPacket, channel: Channel) {
        switch packet {
        case let .connect(connect):
            let identifier = connect.clientID.isEmpty ? "anonymous-\(connectionID)" : connect.clientID
            clientID = identifier
            will = connect.will
            cleanSession = connect.cleanSession
            let resumed = broker.connectionAuthenticated(
                id: connectionID,
                clientID: identifier,
                will: connect.will,
                cleanSession: connect.cleanSession
            )
            channel.writeAndFlush(MQTTPacketEncoder.connack(sessionPresent: resumed), promise: nil)

        case let .subscribe(subscribe):
            guard let clientID else { return }
            let granted = broker.addSubscriptions(clientID: clientID, requests: subscribe.requests)
            channel.writeAndFlush(
                MQTTPacketEncoder.suback(packetID: subscribe.packetID, returnCodes: granted),
                promise: nil
            )
            deliverRetained(
                filters: subscribe.requests.map(\.filter),
                granted: granted,
                clientID: clientID,
                channel: channel
            )

        case let .unsubscribe(unsubscribe):
            guard let clientID else { return }
            broker.removeSubscriptions(clientID: clientID, filters: unsubscribe.filters)
            channel.writeAndFlush(MQTTPacketEncoder.unsuback(packetID: unsubscribe.packetID), promise: nil)

        case let .publish(publish):
            broker.handleInboundPublish(publish)
            if publish.qos == 1, let packetID = publish.packetID {
                channel.writeAndFlush(MQTTPacketEncoder.puback(packetID: packetID), promise: nil)
            }

        case .puback:
            break

        case .pingreq:
            channel.writeAndFlush(MQTTPacketEncoder.pingresp(), promise: nil)

        case .disconnect:
            cleanDisconnect = true
        }
    }

    /// Sends retained messages that match a new subscription.
    private func deliverRetained(
        filters: [String],
        granted: [UInt8],
        clientID: String,
        channel: Channel
    ) {
        for message in broker.retainedMessages(matching: filters) {
            let requested = zip(filters, granted)
                .filter { MQTTTopicMatcher.matches(filter: $0.0, topic: message.topic) }
                .map(\.1)
                .max() ?? 0
            guard requested != 0x80 else { continue }
            let qos = min(message.qos, requested)
            let packetID = qos > 0 ? broker.nextOutboundPacketID(clientID: clientID) : nil
            channel.writeAndFlush(
                MQTTPacketEncoder.publish(
                    topic: message.topic,
                    payload: message.payload,
                    qos: qos,
                    retain: true,
                    duplicate: false,
                    packetID: packetID
                ),
                promise: nil
            )
        }
    }
}
