// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import CAxolotyZenoh

/// A synchronous owner for one C façade session handle.
///
/// Session lifecycle, subscription, and polling calls must be serialized. The
/// façade registry is fixed and intentionally does not provide locks.
public struct ZenohSession: ~Copyable {
    private var handle: OpaquePointer?

    /// Creates a closed session value.
    public init() {
        handle = nil
    }

    /// Closes an unclosed handle and discards the result.
    /// The façade releases all state for every close outcome.
    deinit {
        if let handle {
            _ = axoloty_zenoh_close(handle)
        }
    }

    /// Opens a session using bounded configuration bytes.
    ///
    /// - Parameter configuration: The session connectivity settings.
    /// - Returns: A structured result. The session is open only on success.
    public mutating func open(configuration: ZenohConfiguration) -> ZenohResult {
        guard handle == nil else { return .invalidArgument }
        var cSession: OpaquePointer?
        var cConfiguration = axoloty_zenoh_config_t(
            mode: configuration.mode == .client ? AXOLOTY_ZENOH_MODE_CLIENT : AXOLOTY_ZENOH_MODE_PEER,
            connect_endpoint: nil,
            connect_endpoint_length: 0,
            multicast_scouting_enabled: configuration.multicastScoutingEnabled
        )

        let result: axoloty_zenoh_result_t
        if let endpoint = configuration.connectEndpoint {
            guard endpoint.length <= Int(AXOLOTY_ZENOH_MAX_ENDPOINT_BYTES) else { return .invalidArgument }
            result = endpoint.withBytes { bytes, length in
                cConfiguration.connect_endpoint = bytes.assumingMemoryBound(to: UInt8.self)
                cConfiguration.connect_endpoint_length = UInt32(length)
                return axoloty_zenoh_open(&cConfiguration, &cSession)
            }
        } else {
            result = axoloty_zenoh_open(&cConfiguration, &cSession)
        }

        let translated = ZenohResult(cResult: result)
        if translated == .success {
            handle = cSession
        }
        return translated
    }

    /// Closes this session and reports the façade result.
    ///
    /// - Returns: The close result, or `.notOpen` when already closed.
    @discardableResult
    public mutating func close() -> ZenohResult {
        guard let handle else { return .notOpen }
        let result = ZenohResult(cResult: axoloty_zenoh_close(handle))
        self.handle = nil
        return result
    }

    /// Publishes borrowed key and payload bytes synchronously.
    ///
    /// - Parameters:
    ///   - key: A canonical Zenoh key expression.
    ///   - payload: The bytes to publish.
    /// - Returns: A structured façade result.
    public func publish(key: ByteSlice, payload: ByteSlice) -> ZenohResult {
        guard let handle else { return .notOpen }
        guard key.length <= ZenohFrameStorage.keyCapacity,
              payload.length <= ZenohFrameStorage.payloadCapacity else {
            return .invalidArgument
        }
        return key.withBytes { keyBytes, keyLength in
            payload.withBytes { payloadBytes, payloadLength in
                ZenohResult(cResult: axoloty_zenoh_publish(
                    handle,
                    keyBytes.assumingMemoryBound(to: UInt8.self),
                    UInt32(keyLength),
                    payloadLength == 0 ? nil : payloadBytes.assumingMemoryBound(to: UInt8.self),
                    UInt32(payloadLength)
                ))
            }
        }
    }

    /// Subscribes to one canonical key expression.
    ///
    /// - Parameter key: The bounded key expression to receive.
    /// - Returns: A structured façade result.
    public func subscribe(key: ByteSlice) -> ZenohResult {
        guard let handle else { return .notOpen }
        guard key.length <= ZenohFrameStorage.keyCapacity else { return .invalidArgument }
        return key.withBytes { bytes, length in
            ZenohResult(cResult: axoloty_zenoh_subscribe(
                handle,
                bytes.assumingMemoryBound(to: UInt8.self),
                UInt32(length)
            ))
        }
    }

    /// Removes the active subscription and discards its queued frames.
    ///
    /// - Returns: A structured façade result.
    public func unsubscribe() -> ZenohResult {
        guard let handle else { return .notOpen }
        return ZenohResult(cResult: axoloty_zenoh_unsubscribe(handle))
    }

    /// Copies the oldest queued frame into caller-owned fixed-inline storage.
    ///
    /// - Parameter storage: The reusable output storage.
    /// - Returns: A frame and its lengths, or the distinct polling result.
    public mutating func poll(into storage: inout ZenohFrameStorage) -> ZenohPollResult {
        guard let handle else { return .result(.notOpen) }
        var keyLength: UInt32 = 0
        var payloadLength: UInt32 = 0
        let result = storage.withMutableBuffers { keyBuffer, payloadBuffer in
            axoloty_zenoh_poll(
                handle,
                keyBuffer.baseAddress,
                UInt32(keyBuffer.count),
                &keyLength,
                payloadBuffer.baseAddress,
                UInt32(payloadBuffer.count),
                &payloadLength
            )
        }
        let translated = ZenohResult(cResult: result)
        guard translated == .success else { return .result(translated) }
        storage.setLengths(key: Int(keyLength), payload: Int(payloadLength))
        return .frame(ZenohFrame(keyLength: Int(keyLength), payloadLength: Int(payloadLength)))
    }
}
