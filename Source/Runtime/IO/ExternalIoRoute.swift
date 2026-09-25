// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyObjectModel
import AxolotyWire

/// A validated exact route for an external IO source.
///
/// The portable grammar is carrier-neutral: bounded UTF-8, no control scalars,
/// and no empty slash-separated segments. Each transport applies its own
/// additional route rules when it uses this value.
public struct ExternalIoRoute: Sendable, Hashable {
    let route: String
    let routeBytes: BoundedEncodedText<256>

    /// Creates an exact external route.
    ///
    /// - Parameter route: A bounded exact key with non-empty path segments.
    /// - Throws: ``AxolotyError`` when the route is empty, oversized, contains
    ///   a control scalar, or has an empty slash-separated segment.
    public init(_ route: String) throws(AxolotyError) {
        let bytes = Array(route.utf8)
        guard !bytes.isEmpty, bytes.count <= WireBufferConfig.maxTopicLength else {
            throw AxolotyError.invalidArgument(argument: "route", reason: "must contain 1...256 UTF-8 bytes")
        }
        guard !route.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw AxolotyError.invalidArgument(argument: "route", reason: "must not contain control characters")
        }
        guard bytes.first != 0x2F, bytes.last != 0x2F else {
            throw AxolotyError.invalidArgument(argument: "route", reason: "must not start or end with '/'")
        }
        var previousWasSeparator = false
        for byte in bytes {
            if byte == 0x2F {
                guard !previousWasSeparator else {
                    throw AxolotyError.invalidArgument(argument: "route", reason: "must not contain empty segments")
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
            throw AxolotyError.invalidArgument(argument: "route", reason: "must contain 1 to 256 UTF-8 bytes")
        }
        self.route = route
        self.routeBytes = encoded
    }
}

/// A copied inbound frame admitted by a transport boundary.
public enum RuntimeInboundFrame: Sendable, Equatable {
    /// A Coaty Core profile frame.
    case profile(route: String, payload: [UInt8], nowMS: UInt32)
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
