// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A pure admission decision produced before encoding state commits.
public enum IoPublicationDecision: Sendable, Equatable {
    /// Emit the caller's current value.
    case emitCurrent
    /// Replace the source's one pending latest value.
    case replaceLatest
    /// Drop the current value because the effective interval has not elapsed.
    case throttled
    /// Do not emit because the source has no active association.
    case notAssociated
}

/// Portable two-phase publication timing state.
public struct IoPublicationStateMachine: Sendable {
    private var hasEmission: Bool
    private var lastEmissionMS: UInt32

    /// Creates an emission-ready state machine.
    public init() {
        hasEmission = false
        lastEmissionMS = 0
    }

    /// Plans admission without mutating timing state.
    ///
    /// - Parameters:
    ///   - policy: Local source publication policy.
    ///   - association: Complete processor-owned association projection.
    ///   - nowMS: Wrapping monotonic time in milliseconds.
    /// - Returns: The exhaustive admission decision.
    public borrowing func decision(
        policy: IoPublicationPolicy,
        association: IoAssociationState,
        nowMS: UInt32
    ) -> IoPublicationDecision {
        guard association.hasAssociations else { return .notAssociated }
        guard hasEmission else { return .emitCurrent }

        let localInterval: UInt32
        switch policy {
        case .immediate: localInterval = 0
        case .latest(let interval), .throttle(let interval): localInterval = interval
        }
        let effectiveInterval = max(localInterval, association.recommendedUpdateRateMS ?? 0)
        guard nowMS &- lastEmissionMS >= effectiveInterval else {
            if case .latest = policy { return .replaceLatest }
            return .throttled
        }
        return .emitCurrent
    }

    /// Commits the time of a processor-accepted emission.
    ///
    /// - Parameter nowMS: Wrapping monotonic emission time.
    public mutating func commitEmission(at nowMS: UInt32) {
        hasEmission = true
        lastEmissionMS = nowMS
    }

    /// Clears all transport-scoped timing state.
    public mutating func clear() {
        hasEmission = false
        lastEmissionMS = 0
    }
}
