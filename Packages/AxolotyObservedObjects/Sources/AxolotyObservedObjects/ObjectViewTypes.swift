// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyWire

/// An explicit monotonic tick supplied by the application.
///
/// The view never reads a clock. Callers pass the same tick domain to
/// ``ObjectView/apply(_:in:observedAt:)``, ``ObjectView/snapshot(for:at:)``,
/// and ``ObjectView/expire(at:)``.
public typealias ObjectViewTick = UInt64

/// A non-authoritative identifier for the peer that reported an observation.
///
/// The view compares revisions only when both the source and the revision
/// domain match. It never infers authority from a source identifier.
public struct ObjectSource: Hashable, Sendable {
    /// The application-owned source identifier.
    public let rawValue: UUID16

    /// Creates a source identifier.
    ///
    /// - Parameter rawValue: The application-owned identifier.
    public init(rawValue: UUID16) {
        self.rawValue = rawValue
    }
}

/// How the application received an object observation.
public enum ObjectDeliveryKind: Sendable, Equatable {
    /// A passive Advertise event.
    case advertise
    /// A correlated Resolve response.
    case resolve
}

/// An application-owned revision comparison domain.
///
/// Two revisions are comparable only when they carry the same domain. A
/// version convention that the application already owns selects the domain.
public struct RevisionDomain: Hashable, Sendable {
    /// The application-owned domain identifier.
    public let rawValue: UInt64

    /// Creates a revision domain.
    ///
    /// - Parameter rawValue: The application-owned domain identifier.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// An optional application-supplied revision for one observation.
public struct ObjectRevision: Sendable, Equatable {
    /// The comparison domain selected by the application.
    public let domain: RevisionDomain
    /// The application-owned revision value within ``domain``.
    public let value: Int64

    /// Creates a revision.
    ///
    /// - Parameters:
    ///   - domain: The comparison domain. The default domain is `0`.
    ///   - value: The application-owned revision value.
    public init(domain: RevisionDomain = RevisionDomain(rawValue: 0), value: Int64) {
        self.domain = domain
        self.value = value
    }

}

/// A structured failure raised while configuring or using a view.
public struct ObjectViewError: Error, Sendable, Equatable {
    /// The machine-readable failure category.
    public enum Reason: Sendable, Equatable {
        /// The watched identifier list exceeds the fixed maximum.
        case tooManyWatchedObjects
        /// The watched identifier list contains the same identifier twice.
        case duplicateWatchedObject
        /// A stale or retention interval is zero or out of order.
        case invalidRetentionPolicy
        /// The observation does not name a watched object.
        case unwatchedObjectID
        /// One encoded object exceeds the fixed byte ceiling.
        case objectBytesExceedCapacity
        /// The encoded object is malformed or lacks a valid identity.
        case invalidObjectBytes
        /// The encoded object's identity differs from the observation identity.
        case objectIdentityMismatch
        /// The observation belongs to a different wire profile.
        case profileMismatch
        /// The session token belongs to an attachment that has been replaced.
        case staleSession
        /// The projection requires JSON but the candidate uses another profile.
        case unsupportedTypedProjection
        /// A runtime event did not contain a valid object or withdrawal.
        case invalidEventPayload
        /// A withdrawal could not be retained within the reporter limit.
        case withdrawalCapacityExceeded
        /// A reconciliation timeout was outside the monotonic comparison range.
        case invalidReconciliationTimeout
        /// The application schema did not decode the retained object.
        case invalidTypedProjection
    }

    /// The machine-readable category.
    public let reason: Reason

    /// Creates a structured view error.
    ///
    /// - Parameter reason: The machine-readable category.
    public init(_ reason: Reason) {
        self.reason = reason
    }
}

/// The fixed freshness and retention policy for one view.
public struct ObjectViewConfiguration: Sendable, Equatable {
    /// The fixed maximum number of watched object identifiers.
    public static let maximumWatchedObjects = 8
    /// The fixed maximum number of retained candidates per identifier.
    public static let maximumCandidatesPerObject = 2
    /// The fixed maximum encoded size of one retained object.
    public static let maximumObjectBytes = 2048

    /// The age at which a candidate becomes stale.
    public let staleAfterTicks: ObjectViewTick
    /// The age at which a candidate's bytes are hidden and released.
    public let retainForTicks: ObjectViewTick

    /// Creates a freshness and retention policy.
    ///
    /// - Parameters:
    ///   - staleAfterTicks: A positive stale boundary.
    ///   - retainForTicks: A retention boundary at or after the stale
    ///     boundary.
    /// - Throws: ``ObjectViewError/Reason/invalidRetentionPolicy`` when either
    ///   boundary is non-positive or retention precedes staleness.
    public init(
        staleAfterTicks: ObjectViewTick,
        retainForTicks: ObjectViewTick
    ) throws(ObjectViewError) {
        guard staleAfterTicks > 0, retainForTicks >= staleAfterTicks else {
            throw ObjectViewError(.invalidRetentionPolicy)
        }
        self.staleAfterTicks = staleAfterTicks
        self.retainForTicks = retainForTicks
    }
}

/// An owned observation supplied by the application.
public struct ObjectObservation: Sendable, Equatable {
    /// The watched object identifier that this payload claims.
    public let objectID: ObjectID
    /// The peer that reported the payload.
    public let source: ObjectSource
    /// Whether the application received the payload passively or by Resolve.
    public let delivery: ObjectDeliveryKind
    /// The wire profile of the exact payload bytes.
    public let profile: WireProfile
    /// An optional application-owned revision.
    public let revision: ObjectRevision?
    /// The exact encoded object bytes copied into the view on admission.
    public let bytes: [UInt8]

    /// Creates an observation.
    ///
    /// - Parameters:
    ///   - objectID: The watched object identifier that the payload claims.
    ///   - source: The peer that reported the payload.
    ///   - delivery: Whether the payload arrived passively or by Resolve.
    ///   - profile: The wire profile of ``bytes``.
    ///   - revision: An optional application-owned revision.
    ///   - bytes: The exact encoded object bytes.
    public init(
        objectID: ObjectID,
        source: ObjectSource,
        delivery: ObjectDeliveryKind,
        profile: WireProfile,
        revision: ObjectRevision?,
        bytes: [UInt8]
    ) {
        self.objectID = objectID
        self.source = source
        self.delivery = delivery
        self.profile = profile
        self.revision = revision
        self.bytes = bytes
    }
}

/// The bounded result of admitting one observation.
public enum ObservationAdmission: Sendable, Equatable {
    /// The observation was retained as a new candidate.
    case admitted
    /// The observation matched an existing candidate exactly and refreshed it.
    case coalesced
    /// The observation replaced older candidates from the same source and
    /// domain.
    case superseded(removedCandidates: Int)
    /// The observation was older than an existing same-source revision and
    /// did not change retained evidence.
    case rejectedOutdatedRevision
    /// The per-object candidate capacity was full. The admitted payloads did
    /// not change and the view recorded capacity uncertainty.
    case rejectedCapacity
}

/// Why a snapshot carries less certainty than its retained bytes alone imply.
public struct ObjectUncertainty: OptionSet, Sendable, Equatable, Hashable {
    /// The raw option bits.
    public let rawValue: UInt8

    /// Creates an uncertainty set from raw bits.
    ///
    /// - Parameter rawValue: The option bits.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// A candidate was rejected because the per-object slot capacity was full.
    public static let capacitySaturation = ObjectUncertainty(rawValue: 1 << 0)
    /// The attachment lost continuity, so passive coverage is incomplete.
    public static let continuityLoss = ObjectUncertainty(rawValue: 1 << 1)
    /// A conflicting claim expired, so remaining evidence cannot imply that the
    /// dispute was resolved.
    public static let conflictEvidenceExpired = ObjectUncertainty(rawValue: 1 << 2)
    /// A reporter withdrew advertised evidence. Separate runtime streams cannot
    /// establish whether the withdrawal came before or after an advertisement.
    public static let withdrawalObserved = ObjectUncertainty(rawValue: 1 << 3)
}

/// The object-level freshness of retained evidence at one supplied tick.
public enum ObjectFreshness: Sendable, Equatable {
    /// No evidence is retained or the last evidence expired.
    case unobserved
    /// At least one candidate is within the stale boundary.
    case fresh
    /// The newest candidate is at or after the stale boundary but still
    /// retained.
    case stale
    /// The bytes are hidden because the retention boundary was reached.
    case expired
}

/// One owned, read-only retained candidate.
public struct ObjectCandidate: Sendable, Equatable {
    /// The peer that reported this candidate.
    public let source: ObjectSource
    /// How the application received this candidate.
    public let delivery: ObjectDeliveryKind
    /// The application-owned revision supplied with this candidate.
    public let revision: ObjectRevision?
    /// The supplied tick at which this candidate was last observed.
    public let observedAtTick: ObjectViewTick
    /// The wire profile of ``bytes``.
    public let profile: WireProfile
    /// The object type decoded from the retained envelope.
    public let objectType: ObjectType
    /// The exact encoded object bytes, retained without re-encoding.
    public let bytes: [UInt8]

    init(
        source: ObjectSource,
        delivery: ObjectDeliveryKind,
        revision: ObjectRevision?,
        observedAtTick: ObjectViewTick,
        profile: WireProfile,
        objectType: ObjectType,
        bytes: [UInt8]
    ) {
        self.source = source
        self.delivery = delivery
        self.revision = revision
        self.observedAtTick = observedAtTick
        self.profile = profile
        self.objectType = objectType
        self.bytes = bytes
    }

    /// Decodes the retained JSON bytes with an application schema.
    ///
    /// The candidate keeps its exact bytes when the schema does not match. A
    /// caller that owns a version convention selects the schema itself; the
    /// view never infers one from the wire profile.
    ///
    /// - Parameter type: The manual or generated schema to decode.
    /// - Returns: The decoded application value.
    /// - Throws: ``ObjectViewError/Reason/unsupportedTypedProjection`` for a
    ///   non-JSON candidate, or
    ///   ``ObjectViewError/Reason/invalidTypedProjection`` when the schema does
    ///   not decode the retained object.
    public func decode<Schema: ObjectSchema>(
        _ type: Schema.Type
    ) throws(ObjectViewError) -> Schema {
        guard profile == .coaty3JSON else {
            throw ObjectViewError(.unsupportedTypedProjection)
        }
        var decoded: Schema?
        var failure: ObjectViewError?
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                failure = ObjectViewError(.invalidTypedProjection)
                return
            }
            do {
                let object = try Object<Schema>(
                    decoding: ByteSlice(bytes: base, length: buffer.count)
                )
                decoded = object.value
            } catch {
                failure = ObjectViewError(.invalidTypedProjection)
            }
        }
        if let failure { throw failure }
        guard let decoded else { throw ObjectViewError(.invalidTypedProjection) }
        return decoded
    }
}

/// The evidence a snapshot exposes for one watched object.
public enum ObjectEvidence: Sendable, Equatable {
    /// No evidence is retained.
    case unobserved
    /// Exactly one candidate is visible.
    case observed(ObjectCandidate)
    /// More than one candidate is visible. The view does not choose authority.
    case conflicting([ObjectCandidate])
    /// Retained candidates reached retention and their bytes are hidden.
    case expired
}

/// An owned, read-only projection of one watched object.
public struct ObjectSnapshot: Sendable, Equatable {
    /// The watched object identifier.
    public let objectID: ObjectID
    /// The visible evidence at the supplied tick.
    public let evidence: ObjectEvidence
    /// The freshness derived from the newest retained candidate.
    public let freshness: ObjectFreshness
    /// Uncertainty that survives hiding or rejection.
    public let uncertainty: ObjectUncertainty
    /// The age of the newest retained candidate, including hidden bytes.
    public let ageTicks: ObjectViewTick?

    init(
        objectID: ObjectID,
        evidence: ObjectEvidence,
        freshness: ObjectFreshness,
        uncertainty: ObjectUncertainty,
        ageTicks: ObjectViewTick?
    ) {
        self.objectID = objectID
        self.evidence = evidence
        self.freshness = freshness
        self.uncertainty = uncertainty
        self.ageTicks = ageTicks
    }
}

/// An opaque token for one attachment session.
///
/// The view issues the token. Callers cannot construct one, and a token from a
/// replaced attachment is rejected.
public final class ObservationSession: Sendable {
    init() {}
}
