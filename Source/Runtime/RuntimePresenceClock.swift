// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

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

/// Injectable presence dependencies for one executor.
package struct RuntimePresenceEnvironment: Sendable {
    /// The clock shared by inbound stamping, refresh, and expiry.
    package var clock: RuntimePresenceClock
    /// The owner epoch for this runtime instance. `nil` selects a random epoch.
    package var ownerEpoch: Int?

    /// Creates a presence environment.
    ///
    /// - Parameters:
    ///   - clock: The monotonic clock used for presence transitions.
    ///   - ownerEpoch: An injectable owner epoch, or `nil` for a random one.
    package init(clock: RuntimePresenceClock = .uptime, ownerEpoch: Int? = nil) {
        if let ownerEpoch {
            precondition((1...Int(Int32.max)).contains(ownerEpoch), "ownerEpoch must fit the wire range")
        }
        self.clock = clock
        self.ownerEpoch = ownerEpoch
    }
}

/// Derives a deterministic refresh phase from one owner and object identity.
///
/// The phase is anchored to the uptime clock, so a reconnect never restarts it.
///
/// - Parameters:
///   - sourceID: The owner's protocol source identity.
///   - objectID: The advertised object identity.
///   - intervalMS: The refresh interval in milliseconds.
/// - Returns: The phase within the refresh interval, in milliseconds.
func runtimePresencePhase(sourceID: UUID16, objectID: UUID16, intervalMS: UInt64) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    let prime: UInt64 = 0x0000_0100_0000_01b3
    withUnsafeBytes(of: sourceID.bytes) { bytes in
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* prime
        }
    }
    withUnsafeBytes(of: objectID.bytes) { bytes in
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* prime
        }
    }
    return hash % intervalMS
}
