// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyObjectModel
import AxolotyWire

/// A validated exact MQTT route for an external IO source.
public struct MQTTExternalIoRoute: Sendable, Hashable {
    let topic: String
    let topicBytes: BoundedEncodedText<128>

    /// Creates an exact external route.
    ///
    /// - Parameter topic: A non-wildcard MQTT topic with non-empty levels.
    /// - Throws: ``AxolotyError`` when the topic is not a bounded exact route.
    public init(_ topic: String) throws {
        let bytes = Array(topic.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else {
            throw AxolotyError.invalidArgument(argument: "topic", reason: "must contain 1...128 UTF-8 bytes")
        }
        guard bytes.first != 0x2F, bytes.last != 0x2F else {
            throw AxolotyError.invalidArgument(argument: "topic", reason: "must not start or end with '/'")
        }
        var previousWasSeparator = false
        for byte in bytes {
            guard byte != 0, byte != 0x23, byte != 0x2B else {
                throw AxolotyError.invalidArgument(argument: "topic", reason: "must not contain NUL, '+' or '#'")
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
        var encoded: BoundedEncodedText<128>?
        let encodedBytes = Self.canonicalEncodedRoute(bytes)
        let mutableTopic = encodedBytes
        mutableTopic.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            encoded = BoundedEncodedText(bytes: ByteSlice(bytes: base, length: buffer.count))
        }
        guard let encoded else {
            throw AxolotyError.invalidArgument(argument: "topic", reason: "must contain 1 to 128 UTF-8 bytes")
        }
        self.topic = topic
        self.topicBytes = encoded
    }

    private static func canonicalEncodedRoute(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
        for byte in bytes {
            switch byte {
            case 0x22:
                result.append(contentsOf: [0x5C, 0x22])
            case 0x5C:
                result.append(contentsOf: [0x5C, 0x5C])
            case 0x08:
                result.append(contentsOf: [0x5C, 0x62])
            case 0x0C:
                result.append(contentsOf: [0x5C, 0x66])
            case 0x0A:
                result.append(contentsOf: [0x5C, 0x6E])
            case 0x0D:
                result.append(contentsOf: [0x5C, 0x72])
            case 0x09:
                result.append(contentsOf: [0x5C, 0x74])
            case 0x01...0x1F:
                result.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]])
            default:
                result.append(byte)
            }
        }
        return result
    }
}

/// A copied inbound frame admitted by a transport boundary.
public enum RuntimeInboundFrame: Sendable, Equatable {
    /// A Coaty Core profile frame.
    case profile(topic: String, payload: [UInt8], nowMS: UInt32)
    /// An exact external IO route and its copied payload.
    case externalIo(route: String, payload: [UInt8], nowMS: UInt32)
}

/// One exhaustive transport effect retained by the host runtime.
public enum RuntimeTransportEffect: Sendable, Equatable {
    /// Publish an owned protocol publication.
    case publish(OwnedProtocolPublication)
    /// Subscribe the exact external route after an association activation.
    case externalRouteActivated(OwnedExternalRouteTransition)
    /// Unsubscribe the exact external route after an association deactivation.
    case externalRouteDeactivated(OwnedExternalRouteTransition)
}
