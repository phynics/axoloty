// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// The result of applying a response to a bounded request ledger.
public enum ProtocolCorrelationOutcome: Equatable, Sendable {
    /// The response matched the outstanding request and consumed it.
    case accepted
    /// The response repeats the most recently accepted correlation ID.
    case duplicate
    /// The response has a different correlation ID from the outstanding request.
    case wrongCorrelation
    /// The request deadline elapsed before the response arrived.
    case expired
}

/// A fixed-storage, single-outstanding request ledger for portable protocol state.
///
/// The ledger owns no clock and performs no asynchronous work. Callers provide
/// monotonic millisecond readings, which keeps host and Embedded behavior
/// identical and makes deadline, duplicate, and wrong-correlation handling
/// deterministic. The state is deliberately one-entry for the first static
/// profile; larger bounded registries belong to a later capacity decision.
public struct ProtocolPendingRequest: ~Copyable {
    private var pendingCorrelation: UUID16?
    private var deadlineMS: UInt32?
    private var resolvedCorrelation: UUID16?

    /// Creates an empty request ledger.
    public init() {
        pendingCorrelation = nil
        deadlineMS = nil
        resolvedCorrelation = nil
    }

    /// Starts one bounded request, returning `false` if one is already pending.
    public mutating func begin(
        correlationID: UUID16,
        nowMS: UInt32,
        timeoutMS: UInt32
    ) -> Bool {
        guard pendingCorrelation == nil else { return false }
        pendingCorrelation = correlationID
        deadlineMS = nowMS &+ timeoutMS
        resolvedCorrelation = nil
        return true
    }

    /// Expires the pending request when `nowMS` reaches its deadline.
    public mutating func expire(nowMS: UInt32) -> Bool {
        guard let deadlineMS, Self.hasReached(nowMS, deadlineMS: deadlineMS) else { return false }
        pendingCorrelation = nil
        self.deadlineMS = nil
        return true
    }

    /// Applies a response and records the accepted correlation for duplicate detection.
    public mutating func accept(
        correlationID: UUID16,
        nowMS: UInt32
    ) -> ProtocolCorrelationOutcome {
        if expire(nowMS: nowMS) { return .expired }
        if correlationID == resolvedCorrelation { return .duplicate }
        guard pendingCorrelation == correlationID else { return .wrongCorrelation }
        pendingCorrelation = nil
        deadlineMS = nil
        resolvedCorrelation = correlationID
        return .accepted
    }

    private static func hasReached(_ nowMS: UInt32, deadlineMS: UInt32) -> Bool {
        Int32(bitPattern: nowMS &- deadlineMS) >= 0
    }
}
