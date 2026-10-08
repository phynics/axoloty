// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Provides a monotonic timestamp for deterministic duration calculation.
public protocol AxolotyTimingClock: Sendable {
    /// Returns monotonic seconds.
    ///
    /// - Returns: A monotonic timestamp in seconds.
    func now() -> TimeInterval
}

/// The production monotonic timing clock.
public struct AxolotyContinuousTimingClock: AxolotyTimingClock {
    /// Creates a monotonic clock.
    public init() {}

    /// Returns monotonic seconds from `DispatchTime`.
    ///
    /// - Returns: A monotonic timestamp in seconds.
    public func now() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
