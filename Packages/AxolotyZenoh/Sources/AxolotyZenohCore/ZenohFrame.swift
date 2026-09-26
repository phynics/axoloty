// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Metadata for one received frame stored in `ZenohFrameStorage`.
public struct ZenohFrame: Equatable {
    /// Number of bytes in the frame's key expression.
    public let keyLength: Int
    /// Number of bytes in the frame's payload.
    public let payloadLength: Int

    init(keyLength: Int, payloadLength: Int) {
        self.keyLength = keyLength
        self.payloadLength = payloadLength
    }
}

/// The outcome of polling a Zenoh session.
public enum ZenohPollResult: Equatable {
    /// A complete frame was copied into caller-owned fixed storage.
    case frame(ZenohFrame)
    /// Polling did not produce a frame.
    case result(ZenohResult)
}
