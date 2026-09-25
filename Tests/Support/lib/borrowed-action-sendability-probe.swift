// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyWire

// This fixture is intentionally rejected by Swift's strict-concurrency checker.
// A borrowed action must be materialized with `owned()` before it enters an
// escaping task or another asynchronous isolation boundary.
func borrowedActionCannotCrossIsolation(_ action: borrowing BorrowedProtocolAction) {
    requiresSendable(action)
}

func requiresSendable<T: Sendable>(_ value: T) {}

func borrowedByteSliceCannotCrossIsolation(_ value: borrowing ByteSlice) {
    requiresSendable(value)
}

func borrowedTopicCannotCrossIsolation(_ value: borrowing TopicView) {
    requiresSendable(value)
}

func borrowedMessageCannotCrossIsolation(_ value: borrowing BorrowedMessage) {
    requiresSendable(value)
}

func borrowedReaderCannotCrossIsolation(_ value: borrowing WireReader) {
    requiresSendable(value)
}

func borrowedFieldCannotCrossIsolation(_ value: borrowing WireObjectField) {
    requiresSendable(value)
}

func borrowedJSONViewCannotCrossIsolation(_ value: borrowing WireValueView) {
    requiresSendable(value)
}

func borrowedJSONReaderCannotCrossIsolation(_ value: borrowing WireValueReader) {
    requiresSendable(value)
}

func borrowedFrameCannotCrossIsolation(_ value: borrowing BorrowedProtocolFrame) {
    requiresSendable(value)
}

func borrowedInputCannotCrossIsolation(_ value: borrowing BorrowedProtocolInput) {
    requiresSendable(value)
}

func borrowedDeliveryKeyCannotCrossIsolation(_ value: borrowing BorrowedProtocolDeliveryKey) {
    requiresSendable(value)
}

func borrowedPublishTargetCannotCrossIsolation(_ value: borrowing BorrowedProtocolPublishTarget) {
    requiresSendable(value)
}

func borrowedDeliveryCannotCrossIsolation(_ value: borrowing BorrowedProtocolDelivery) {
    requiresSendable(value)
}

func borrowedPublicationCannotCrossIsolation(_ value: borrowing BorrowedProtocolPublication) {
    requiresSendable(value)
}

func borrowedAssociationCannotCrossIsolation(_ value: borrowing BorrowedIoAssociationTransition) {
    requiresSendable(value)
}

func borrowedActionCannotCrossIsolation(_ value: borrowing BorrowedProtocolAction) {
    requiresSendable(value)
}
