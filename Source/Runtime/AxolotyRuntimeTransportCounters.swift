// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A bounded, transport-neutral snapshot of host transport activity.
///
/// `receivedFrames` counts frames admitted to the runtime receive callback.
/// `publishedFrames` counts successful outbound publications.
/// `receiveDrops` counts inbound samples discarded before that callback for
/// reasons other than oversize rejection, including samples outside an active
/// route and samples rejected by a bounded receive queue. `oversizedSamples`
/// counts inbound samples rejected because their encoded route or payload
/// exceeds adapter capacity. Adapters that cannot observe oversize rejection
/// report zero.
///
/// `sessionOpens` counts successful session opens. `sessionFailures` counts
/// failed opens and failures reported by an open session. `reconnects` counts
/// successful opens after the first successful open. `activeExternalSubscriptions`
/// is the current number of distinct active external routes, not a cumulative
/// total.
public struct RuntimeTransportCounters: Sendable, Equatable {
    /// Frames admitted to the runtime receive callback.
    public var receivedFrames: UInt64 = 0
    /// Successful outbound publications.
    public var publishedFrames: UInt64 = 0
    /// Inbound samples discarded before reaching the runtime callback.
    public var receiveDrops: UInt64 = 0
    /// Inbound samples rejected because their route or payload exceeds adapter capacity.
    public var oversizedSamples: UInt64 = 0
    /// Successful transport-session opens.
    public var sessionOpens: UInt64 = 0
    /// Failed session opens or failures reported by an open session.
    public var sessionFailures: UInt64 = 0
    /// Successful session opens after the first successful open.
    public var reconnects: UInt64 = 0
    /// Current count of distinct active external subscriptions.
    public var activeExternalSubscriptions: UInt64 = 0

    /// Creates an empty counter snapshot.
    public init() {}
}

/// A fixed-size, synchronized counter sink shared by a runtime and its transport.
///
/// Updates allocate no storage. Each cumulative counter saturates at
/// `UInt64.max`; the active-subscription value is replaced atomically.
public final class RuntimeTransportDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var counters = RuntimeTransportCounters()

    /// Creates an empty counter sink.
    public init() {}

    /// Returns a consistent copy of all transport counters.
    public func snapshot() -> RuntimeTransportCounters {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    /// Records one frame admitted to the runtime receive callback.
    public func recordReceivedFrame() {
        update(\.receivedFrames)
    }

    /// Records one successful outbound publication.
    public func recordPublishedFrame() {
        update(\.publishedFrames)
    }

    /// Records one inbound sample discarded before the runtime callback.
    public func recordReceiveDrop() {
        update(\.receiveDrops)
    }

    /// Records one inbound sample rejected because its route or payload exceeds capacity.
    public func recordOversizedSample() {
        update(\.oversizedSamples)
    }

    /// Records one successful session open.
    public func recordSessionOpen() {
        update(\.sessionOpens)
    }

    /// Records one failed session open or one failure reported by an open session.
    public func recordSessionFailure() {
        update(\.sessionFailures)
    }

    /// Records one successful session open after the first successful open.
    public func recordReconnect() {
        update(\.reconnects)
    }

    /// Sets the current number of distinct active external subscriptions.
    ///
    /// - Parameter count: Current active external subscription count.
    public func setActiveExternalSubscriptions(_ count: UInt64) {
        lock.lock()
        counters.activeExternalSubscriptions = count
        lock.unlock()
    }

    private func update(_ keyPath: WritableKeyPath<RuntimeTransportCounters, UInt64>) {
        lock.lock()
        counters[keyPath: keyPath] = counters[keyPath: keyPath] == .max
            ? .max
            : counters[keyPath: keyPath] + 1
        lock.unlock()
    }
}
