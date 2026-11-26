// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Expands a binding's wrapping receipt time within a verified window on the
/// same monotonic clock. A receipt with unknown age cannot refresh a view.
func receiptTick(_ receiptTimeMS: UInt32, within window: ClosedRange<UInt64>) -> UInt64? {
    let duration = window.upperBound - window.lowerBound
    guard duration <= UInt64(Int32.max) else { return nil }

    let start = UInt32(truncatingIfNeeded: window.lowerBound)
    let offset = UInt64(receiptTimeMS &- start)
    guard offset <= duration else { return nil }
    return window.lowerBound + offset
}
