// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// The result of one atomic processor operation.
public enum ProtocolProcessOutcome: Sendable, Equatable {
    /// The operation was accepted and appended to the sink.
    case accepted
    /// The route is unrelated to this binding.
    case ignored
    /// The operation was rejected without state mutation.
    case rejected(ProtocolError.Code)
}

/// A closed borrowed input accepted by the protocol processor.
public enum BorrowedProtocolInput {
    /// A Coaty profile frame with a parsed routing key and borrowed payload.
    case profile(BorrowedProtocolFrame)
    /// An exact external IO route and its borrowed payload.
    case externalIo(route: ByteSlice, payload: ByteSlice)
}

/// A compact, fixed-storage state observation.
public struct ProtocolStateSnapshot: Sendable, Equatable {
    /// Number of active association records.
    public let activeRecords: Int
    /// Number of active association routes.
    public let activeAssociations: Int
    /// Reserved object count reported by future object adapters.
    public let activeObjects: Int
    /// Reserved pending count reported by future multi-request adapters.
    public let pendingCorrelations: Int
    /// Monotonic processor generation.
    public let generation: UInt32

    /// Creates a state snapshot.
    public init(
        activeRecords: Int,
        activeAssociations: Int,
        generation: UInt32,
        activeObjects: Int = 0,
        pendingCorrelations: Int = 0
    ) {
        self.activeRecords = activeRecords
        self.activeAssociations = activeAssociations
        self.activeObjects = activeObjects
        self.pendingCorrelations = pendingCorrelations
        self.generation = generation
    }
}

/// Caller-owned fixed-inline identity projection for diagnostics and replay.
///
/// The processor never allocates this projection. A caller supplies one when
/// it needs identities; steady-state processing uses only the count snapshot.
public struct ProtocolFixedStateSnapshot<let capacity: Int>: ~Copyable {
    /// Active advertised object identities.
    public private(set) var activeObjectIDs: InlineArray<capacity, UUID16?>
    /// Outstanding request correlations.
    public private(set) var pendingCorrelationIDs: InlineArray<capacity, UUID16?>
    /// Source identities for active association records.
    public private(set) var associationSourceIDs: InlineArray<capacity, UUID16?>
    /// Actor identities for active association records.
    public private(set) var associationActorIDs: InlineArray<capacity, UUID16?>
    /// Number of active object identities in ``activeObjectIDs``.
    public private(set) var activeObjectCount = 0
    /// Number of pending identities in ``pendingCorrelationIDs``.
    public private(set) var pendingCorrelationCount = 0
    /// Number of association records in the paired association buffers.
    public private(set) var associationCount = 0

    /// Creates an empty caller-owned projection.
    public init() {
        self.activeObjectIDs = InlineArray(repeating: nil)
        self.pendingCorrelationIDs = InlineArray(repeating: nil)
        self.associationSourceIDs = InlineArray(repeating: nil)
        self.associationActorIDs = InlineArray(repeating: nil)
    }

    mutating func reset() {
        for index in 0..<capacity {
            activeObjectIDs[index] = nil
            pendingCorrelationIDs[index] = nil
            associationSourceIDs[index] = nil
            associationActorIDs[index] = nil
        }
        activeObjectCount = 0
        pendingCorrelationCount = 0
        associationCount = 0
    }

    mutating func appendObject(_ id: UUID16) {
        guard activeObjectCount < capacity else { return }
        activeObjectIDs[activeObjectCount] = id
        activeObjectCount += 1
    }

    mutating func appendPending(_ id: UUID16) {
        guard pendingCorrelationCount < capacity else { return }
        pendingCorrelationIDs[pendingCorrelationCount] = id
        pendingCorrelationCount += 1
    }

    mutating func appendAssociation(source: UUID16, actor: UUID16) {
        guard associationCount < capacity else { return }
        associationSourceIDs[associationCount] = source
        associationActorIDs[associationCount] = actor
        associationCount += 1
    }
}
