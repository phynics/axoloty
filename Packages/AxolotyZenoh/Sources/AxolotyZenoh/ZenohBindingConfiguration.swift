// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyZenohCore

/// The connectivity mode supported by the host Zenoh binding.
public enum ZenohBindingMode: Sendable, Equatable {
    /// Connect to a Zenoh router.
    case client
}

/// A specific validation failure in ``ZenohBindingConfiguration``.
public enum ZenohBindingConfigurationError: Error, Sendable, Equatable {
    /// The connect endpoint is empty, too long, or contains unsupported bytes.
    case invalidConnectEndpoint
    /// The profile-key limit is outside the supported range.
    case maximumProfileKeyBytesOutOfRange
    /// The external-route limit is outside the supported range.
    case maximumExternalRoutesOutOfRange
    /// The receive queue capacity is outside the supported range.
    case receiveQueueCapacityOutOfRange
    /// The receive key capacity is outside the supported range.
    case receiveKeyCapacityOutOfRange
    /// The receive payload capacity is outside the supported range.
    case receivePayloadCapacityOutOfRange
}

/// Bounded client settings for the host Zenoh runtime binding.
///
/// Zenoh's synchronous session-open API does not expose a meaningful deadline
/// that the binding can enforce without adding its own clock or background
/// task, so this configuration does not include a timeout. The receive limits
/// may reduce the façade's fixed capacities but cannot exceed them.
public struct ZenohBindingConfiguration: Sendable, Equatable {
    /// The supported Zenoh connectivity mode.
    public let mode: ZenohBindingMode
    /// The router endpoint, expressed as a Zenoh endpoint string.
    public let connectEndpoint: String
    /// The largest Coaty profile key accepted by the binding, in UTF-8 bytes.
    public let maximumProfileKeyBytes: Int
    /// The maximum number of exact external routes tracked at once.
    public let maximumExternalRoutes: Int
    /// The maximum number of frames admitted to the receive queue.
    public let receiveQueueCapacity: Int
    /// The maximum key-expression size admitted from received frames, in bytes.
    public let receiveKeyCapacity: Int
    /// The maximum payload size admitted from received frames, in bytes.
    public let receivePayloadCapacity: Int

    /// Creates validated host Zenoh binding settings.
    ///
    /// - Parameters:
    ///   - mode: Connectivity mode. Only client mode is supported.
    ///   - connectEndpoint: Router endpoint. Must contain 1...512 non-space
    ///     printable ASCII bytes (`0x21...0x7E`) and must not contain `"` or `\\`.
    ///   - maximumProfileKeyBytes: Largest Coaty profile key accepted. Must be
    ///     in `1...256`.
    ///   - maximumExternalRoutes: Maximum exact external routes tracked. Must
    ///     be in `1...64`.
    ///   - receiveQueueCapacity: Maximum admitted receive frames. Must be in
    ///     `1...4`.
    ///   - receiveKeyCapacity: Maximum admitted received key bytes. Must be in
    ///     `1...256`.
    ///   - receivePayloadCapacity: Maximum admitted received payload bytes.
    ///     Must be in `1...2048`.
    /// - Throws: A ``ZenohBindingConfigurationError`` identifying the invalid
    ///   setting.
    public init(
        mode: ZenohBindingMode = .client,
        connectEndpoint: String = "tcp/127.0.0.1:7447",
        maximumProfileKeyBytes: Int = 256,
        maximumExternalRoutes: Int = 64,
        receiveQueueCapacity: Int = 4,
        receiveKeyCapacity: Int = ZenohFrameStorage.keyCapacity,
        receivePayloadCapacity: Int = ZenohFrameStorage.payloadCapacity
    ) throws(ZenohBindingConfigurationError) {
        let endpointBytes = Array(connectEndpoint.utf8)
        guard (1...512).contains(endpointBytes.count),
              endpointBytes.allSatisfy({ (0x21...0x7E).contains($0) && $0 != 0x22 && $0 != 0x5C }) else {
            throw .invalidConnectEndpoint
        }
        guard (1...ZenohFrameStorage.keyCapacity).contains(maximumProfileKeyBytes) else {
            throw .maximumProfileKeyBytesOutOfRange
        }
        guard (1...64).contains(maximumExternalRoutes) else {
            throw .maximumExternalRoutesOutOfRange
        }
        guard (1...4).contains(receiveQueueCapacity) else {
            throw .receiveQueueCapacityOutOfRange
        }
        guard (1...ZenohFrameStorage.keyCapacity).contains(receiveKeyCapacity) else {
            throw .receiveKeyCapacityOutOfRange
        }
        guard (1...ZenohFrameStorage.payloadCapacity).contains(receivePayloadCapacity) else {
            throw .receivePayloadCapacityOutOfRange
        }
        self.mode = mode
        self.connectEndpoint = connectEndpoint
        self.maximumProfileKeyBytes = maximumProfileKeyBytes
        self.maximumExternalRoutes = maximumExternalRoutes
        self.receiveQueueCapacity = receiveQueueCapacity
        self.receiveKeyCapacity = receiveKeyCapacity
        self.receivePayloadCapacity = receivePayloadCapacity
    }
}
