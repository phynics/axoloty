// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import CAxolotyZenoh

/// The stable result of a Zenoh façade operation.
public enum ZenohResult: Equatable {
    /// The operation completed successfully.
    case success
    /// An argument was null, malformed, or outside its fixed bound.
    case invalidArgument
    /// The session is not open, or no subscription is active.
    case notOpen
    /// The fixed façade session registry is full.
    case capacityExceeded
    /// Zenoh rejected the operation or the carrier failed.
    case transportError
    /// No queued frame or drop notification is available.
    case queueEmpty
    /// A frame was dropped because the receive queue was full.
    case queueFull
    /// A frame was dropped because its key or payload exceeded the receive bound.
    case frameTooLarge

    /// Converts one C façade result without collapsing distinct errors.
    ///
    /// - Parameter result: A result returned by `CAxolotyZenoh`.
    /// - Note: Unknown C values trap; adding a code requires a Swift case and a matching mapping test.
    init(cResult result: axoloty_zenoh_result_t) {
        switch result {
        case AXOLOTY_ZENOH_OK:
            self = .success
        case AXOLOTY_ZENOH_INVALID_ARGUMENT:
            self = .invalidArgument
        case AXOLOTY_ZENOH_NOT_OPEN:
            self = .notOpen
        case AXOLOTY_ZENOH_CAPACITY_EXCEEDED:
            self = .capacityExceeded
        case AXOLOTY_ZENOH_TRANSPORT_ERROR:
            self = .transportError
        case AXOLOTY_ZENOH_QUEUE_EMPTY:
            self = .queueEmpty
        case AXOLOTY_ZENOH_QUEUE_FULL:
            self = .queueFull
        case AXOLOTY_ZENOH_FRAME_TOO_LARGE:
            self = .frameTooLarge
        default:
            preconditionFailure("CAxolotyZenoh added a result without a Swift mapping")
        }
    }
}
