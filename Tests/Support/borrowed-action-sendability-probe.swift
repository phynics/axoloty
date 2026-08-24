// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol

// This fixture is intentionally rejected by Swift's strict-concurrency checker.
// A borrowed action must be materialized with `owned()` before it enters an
// escaping task or another asynchronous isolation boundary.
func borrowedActionCannotCrossIsolation(_ action: borrowing BorrowedProtocolAction) {
    requiresSendable(action)
}

func requiresSendable<T: Sendable>(_ value: T) {}
