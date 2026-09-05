// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyObjectModel
import AxolotyWire

/// A validated exact MQTT route for an external IO source.
public struct MQTTExternalIoRoute: Sendable, Hashable {
    let topic: String
    let topicBytes: BoundedEncodedText<256>

    /// Creates an exact external route.
    ///
    /// - Parameter topic: A non-wildcard MQTT topic with non-empty levels.
    /// - Throws: ``AxolotyError`` when the topic is not a bounded exact route.
    public init(_ topic: String) throws {
        let bytes = Array(topic.utf8)
        guard !bytes.isEmpty, bytes.count <= WireBufferConfig.maxTopicLength else {
            throw AxolotyError.invalidArgument(argument: "topic", reason: "must contain 1...256 UTF-8 bytes")
        }
        guard bytes.first != 0x2F, bytes.last != 0x2F else {
            throw AxolotyError.invalidArgument(argument: "topic", reason: "must not start or end with '/'")
        }
        var previousWasSeparator = false
        for byte in bytes {
            guard byte >= 0x20, byte != 0x22, byte != 0x23, byte != 0x2B, byte != 0x5C else {
                throw AxolotyError.invalidArgument(
                    argument: "topic",
                    reason: "must not contain control characters, quotes, backslashes, '+' or '#'"
                )
            }
            if byte == 0x2F {
                guard !previousWasSeparator else {
                    throw AxolotyError.invalidArgument(argument: "topic", reason: "must not contain empty levels")
                }
                previousWasSeparator = true
            } else {
                previousWasSeparator = false
            }
        }
        var encoded: BoundedEncodedText<256>?
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            encoded = BoundedEncodedText(bytes: ByteSlice(bytes: base, length: buffer.count))
        }
        guard let encoded else {
            throw AxolotyError.invalidArgument(argument: "topic", reason: "must contain 1 to 256 UTF-8 bytes")
        }
        self.topic = topic
        self.topicBytes = encoded
    }
}

/// A copied inbound frame admitted by a transport boundary.
public enum RuntimeInboundFrame: Sendable, Equatable {
    /// A Coaty Core profile frame.
    case profile(topic: String, payload: [UInt8], nowMS: UInt32)
    /// An exact external IO route and its copied payload.
    case externalIo(route: String, payload: [UInt8], nowMS: UInt32)
}

/// A finished outbound message: where it goes, and what it carries.
///
/// The runtime resolves the route before handing the message to a transport,
/// so an adapter never needs profile knowledge to address a publication.
public struct RuntimeOutboundMessage: Sendable, Equatable {
    /// The exact route to publish on.
    public let route: String
    /// The copied payload.
    public let payload: [UInt8]

    /// Creates an outbound message.
    public init(route: String, payload: [UInt8]) {
        self.route = route
        self.payload = payload
    }
}

/// One exhaustive transport effect retained by the host runtime.
public enum RuntimeTransportEffect: Sendable, Equatable {
    /// Publish a finished route and payload.
    case publish(RuntimeOutboundMessage)
    /// Subscribe the exact external route after an association activation.
    case externalRouteActivated(OwnedExternalRouteTransition)
    /// Unsubscribe the exact external route after an association deactivation.
    case externalRouteDeactivated(OwnedExternalRouteTransition)
}
