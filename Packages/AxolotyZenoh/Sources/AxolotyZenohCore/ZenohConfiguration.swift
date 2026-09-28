// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// The connectivity mode for a Zenoh session.
public enum ZenohMode: Equatable {
    /// Connect to routers, using scouting if no endpoint is supplied.
    case client
    /// Connect directly to other peers.
    case peer
}

/// Bounded, borrowed settings used to open a Zenoh session.
///
/// Endpoint bytes are read only during `ZenohSession.open(configuration:)`.
/// Keep their backing storage alive through that synchronous call.
public struct ZenohConfiguration {
    /// The Zenoh connectivity mode.
    public var mode: ZenohMode
    /// Optional borrowed printable-ASCII endpoint bytes.
    public var connectEndpoint: ByteSlice?
    /// Whether Zenoh multicast scouting is enabled.
    public var multicastScoutingEnabled: Bool

    /// Creates a session configuration.
    ///
    /// - Parameters:
    ///   - mode: Connectivity mode. Defaults to client mode.
    ///   - connectEndpoint: Optional borrowed endpoint bytes.
    ///   - multicastScoutingEnabled: Whether multicast scouting is enabled.
    public init(
        mode: ZenohMode = .client,
        connectEndpoint: ByteSlice? = nil,
        multicastScoutingEnabled: Bool = false
    ) {
        self.mode = mode
        self.connectEndpoint = connectEndpoint
        self.multicastScoutingEnabled = multicastScoutingEnabled
    }
}
