// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyZenohCore

/// The connectivity mode supported by the host Zenoh binding.
public enum ZenohBindingMode: Sendable, Equatable {
    /// Connect to a Zenoh router.
    case client
    /// Connect directly to other Zenoh peers without a router.
    case peer
}

/// A specific validation failure in ``ZenohBindingConfiguration``.
public enum ZenohBindingConfigurationError: Error, Sendable, Equatable {
    /// The connect endpoint is empty, too long, or contains unsupported bytes.
    case invalidConnectEndpoint
    /// The profile-key limit is outside the supported range.
    case maximumProfileKeyBytesOutOfRange
    /// The external-route limit is outside the supported range.
    case maximumExternalRoutesOutOfRange
    /// The receive key capacity is outside the supported range.
    case receiveKeyCapacityOutOfRange
    /// The receive payload capacity is outside the supported range.
    case receivePayloadCapacityOutOfRange
}

/// Bounded client settings for the host Zenoh runtime binding.
///
/// Zenoh's synchronous session-open API does not expose a meaningful deadline
/// that the binding can enforce without adding its own clock or background
/// task, so this configuration does not include a timeout. Received key and
/// payload limits may reduce the façade's fixed per-frame capacities but cannot
/// exceed them. The receive queue has a fixed depth of four frames per
/// subscription. Two façade subscriber slots are reserved for profile-interest
/// shapes.
/// ``maximumExternalRouteCapacity`` derives the remaining route slots from the
/// façade limit.
public struct ZenohBindingConfiguration: Sendable, Equatable {
    /// The external-route capacity after reserving two profile-interest slots.
    public static let maximumExternalRouteCapacity = ZenohSession.maximumSubscriberCount - 2

    /// The supported Zenoh connectivity mode.
    public let mode: ZenohBindingMode
    /// The router or peer endpoint, expressed as a Zenoh endpoint string.
    ///
    /// Client mode requires a non-empty endpoint. Peer mode accepts an empty
    /// endpoint and discovers peers through multicast scouting.
    public let connectEndpoint: String
    /// Whether Zenoh multicast scouting is enabled for peer discovery.
    public let multicastScoutingEnabled: Bool
    /// The largest Coaty profile key accepted by the binding, in UTF-8 bytes.
    public let maximumProfileKeyBytes: Int
    /// The maximum number of exact external routes tracked at once, in addition
    /// to two reserved profile-interest subscriptions.
    public let maximumExternalRoutes: Int
    /// The maximum key-expression size admitted from received frames, in bytes.
    public let receiveKeyCapacity: Int
    /// The maximum payload size admitted from received frames, in bytes.
    public let receivePayloadCapacity: Int

    /// The client-mode endpoint used when the caller omits one.
    public static let defaultClientConnectEndpoint = "tcp/127.0.0.1:7447"

    /// Creates validated host Zenoh binding settings.
    ///
    /// When `connectEndpoint` is `nil`, client mode uses
    /// ``defaultClientConnectEndpoint`` and peer mode uses an empty endpoint
    /// for scouting discovery. When `multicastScoutingEnabled` is `nil`, client
    /// mode disables scouting and peer mode enables it.
    ///
    /// - Parameters:
    ///   - mode: Connectivity mode. Defaults to client mode.
    ///   - connectEndpoint: Router or peer endpoint. When supplied, it must
    ///     contain 0...512 non-space printable ASCII bytes (`0x21...0x7E`) and
    ///     must not contain `"` or `\\`. Client mode additionally requires at
    ///     least one byte.
    ///   - multicastScoutingEnabled: Whether Zenoh multicast scouting is
    ///     enabled. Defaults to the mode's discovery default.
    ///   - maximumProfileKeyBytes: Largest Coaty profile key accepted. Must be
    ///     in `1...256`.
    ///   - maximumExternalRoutes: Maximum exact external routes tracked in
    ///     addition to the two profile-interest subscriptions. Must be in
    ///     `1...maximumExternalRouteCapacity`.
    ///   - receiveKeyCapacity: Maximum admitted received key bytes. Must be in
    ///     `1...256`.
    ///   - receivePayloadCapacity: Maximum admitted received payload bytes.
    ///     Must be in `1...2048`.
    /// - Throws: A ``ZenohBindingConfigurationError`` identifying the invalid
    ///   setting.
    public init(
        mode: ZenohBindingMode = .client,
        connectEndpoint: String? = nil,
        multicastScoutingEnabled: Bool? = nil,
        maximumProfileKeyBytes: Int = 256,
        maximumExternalRoutes: Int = ZenohBindingConfiguration.maximumExternalRouteCapacity,
        receiveKeyCapacity: Int = ZenohFrameStorage.keyCapacity,
        receivePayloadCapacity: Int = ZenohFrameStorage.payloadCapacity
    ) throws(ZenohBindingConfigurationError) {
        let resolvedEndpoint = connectEndpoint ?? Self.defaultConnectEndpoint(for: mode)
        let resolvedScouting = multicastScoutingEnabled ?? Self.defaultMulticastScouting(for: mode)
        let endpointBytes = Array(resolvedEndpoint.utf8)
        let endpointBounds = mode == .client ? 1...512 : 0...512
        guard endpointBounds.contains(endpointBytes.count),
              endpointBytes.allSatisfy({ (0x21...0x7E).contains($0) && $0 != 0x22 && $0 != 0x5C }) else {
            throw .invalidConnectEndpoint
        }
        guard (1...ZenohFrameStorage.keyCapacity).contains(maximumProfileKeyBytes) else {
            throw .maximumProfileKeyBytesOutOfRange
        }
        guard (1...Self.maximumExternalRouteCapacity).contains(maximumExternalRoutes) else {
            throw .maximumExternalRoutesOutOfRange
        }
        guard (1...ZenohFrameStorage.keyCapacity).contains(receiveKeyCapacity) else {
            throw .receiveKeyCapacityOutOfRange
        }
        guard (1...ZenohFrameStorage.payloadCapacity).contains(receivePayloadCapacity) else {
            throw .receivePayloadCapacityOutOfRange
        }
        self.mode = mode
        self.connectEndpoint = resolvedEndpoint
        self.multicastScoutingEnabled = resolvedScouting
        self.maximumProfileKeyBytes = maximumProfileKeyBytes
        self.maximumExternalRoutes = maximumExternalRoutes
        self.receiveKeyCapacity = receiveKeyCapacity
        self.receivePayloadCapacity = receivePayloadCapacity
    }

    private static func defaultConnectEndpoint(for mode: ZenohBindingMode) -> String {
        switch mode {
        case .client: defaultClientConnectEndpoint
        case .peer: ""
        }
    }

    private static func defaultMulticastScouting(for mode: ZenohBindingMode) -> Bool {
        switch mode {
        case .client: false
        case .peer: true
        }
    }
}
