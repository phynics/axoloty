// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The monotonic clock used for host presence transitions and deadlines.
package struct RuntimePresenceClock: Sendable {
    /// Samples monotonic time in milliseconds.
    package let nowMS: @Sendable () -> UInt64
    /// Waits for an absolute deadline on the same clock or until cancelled.
    package let sleepUntilMS: @Sendable (UInt64) async -> Void

    /// Creates a presence clock from a time source and a cancellation-aware wait.
    package init(
        nowMS: @escaping @Sendable () -> UInt64,
        sleepUntilMS: @escaping @Sendable (UInt64) async -> Void
    ) {
        self.nowMS = nowMS
        self.sleepUntilMS = sleepUntilMS
    }

    static let uptime = Self(nowMS: monotonicUptimeMS) { deadline in
        let now = monotonicUptimeMS()
        if now < deadline {
            try? await Task.sleep(for: .milliseconds(deadline - now), clock: SuspendingClock())
        }
    }
}
