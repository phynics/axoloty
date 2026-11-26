// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyObjectModel
import AxolotyWire

/// A bounded, read-only projection of a fixed set of object identifiers.
///
/// A view starts empty. The application calls ``beginSession()`` before it
/// supplies observations and replaces that session when it attaches to a new
/// event feed. The view retains at most two exact-byte candidates per watched
/// identifier and at most eight identifiers. It never owns a transport,
/// timer, task, or persistence mechanism.
public struct ObjectView: Sendable {
    private struct Bucket {
        var candidates: [ObjectCandidate] = []
        var withdrawnSources: Set<ObjectSource> = []
        var capacitySaturated = false
        var hadConflict = false
        var expiredPreviously = false
    }

    /// The fixed freshness and retention policy for this view.
    public let configuration: ObjectViewConfiguration

    private let profile: WireProfile
    private var buckets: [ObjectID: Bucket]
    private var session: ObservationSession?
    private var continuityLost = false

    /// Creates an empty view for a fixed identifier list.
    ///
    /// - Parameters:
    ///   - objectIDs: The watched identifiers. The list is fixed for the
    ///     lifetime of the view.
    ///   - configuration: The stale and retention boundaries.
    ///   - profile: The wire profile of the attached event feed.
    /// - Throws: ``ObjectViewError/Reason/tooManyWatchedObjects`` when the list
    ///   exceeds eight identifiers, or
    ///   ``ObjectViewError/Reason/duplicateWatchedObject`` when an identifier
    ///   occurs twice.
    public init(
        watching objectIDs: [ObjectID],
        configuration: ObjectViewConfiguration,
        profile: WireProfile = .coaty3JSON
    ) throws(ObjectViewError) {
        guard objectIDs.count <= ObjectViewConfiguration.maximumWatchedObjects else {
            throw ObjectViewError(.tooManyWatchedObjects)
        }
        var next: [ObjectID: Bucket] = [:]
        next.reserveCapacity(objectIDs.count)
        for objectID in objectIDs {
            guard next[objectID] == nil else {
                throw ObjectViewError(.duplicateWatchedObject)
            }
            next[objectID] = Bucket()
        }
        self.configuration = configuration
        self.profile = profile
        self.buckets = next
    }

    /// Starts a new attachment session and discards all prior evidence.
    ///
    /// - Returns: An opaque token accepted only by this attachment.
    public mutating func beginSession() -> ObservationSession {
        let session = ObservationSession()
        self.session = session
        continuityLost = false
        for objectID in Array(buckets.keys) {
            buckets[objectID] = Bucket()
        }
        return session
    }

    /// Validates and admits one observation atomically.
    ///
    /// Admission never mutates retained evidence on a rejected capacity
    /// observation. Identical bytes from the same source and compatible
    /// revision coalesce; a newer same-source revision supersedes older
    /// candidates in the same domain. Cross-source and incomparable claims
    /// remain visible as separate candidates.
    ///
    /// - Parameters:
    ///   - observation: The owned observation to admit.
    ///   - session: The current attachment session.
    ///   - tick: The explicit monotonic observation tick.
    /// - Returns: How the observation affected the retained evidence.
    /// - Throws: ``ObjectViewError/Reason/staleSession`` for a replaced
    ///   session, ``ObjectViewError/Reason/unwatchedObjectID`` for an
    ///   identifier outside the fixed list,
    ///   ``ObjectViewError/Reason/objectBytesExceedCapacity`` for a payload
    ///   above 2,048 bytes, or a validation error for malformed or mismatched
    ///   object bytes, or ``ObjectViewError/Reason/profileMismatch`` for an
    ///   observation in another wire profile.
    @discardableResult
    public mutating func apply(
        _ observation: ObjectObservation,
        in session: ObservationSession,
        observedAt tick: ObjectViewTick
    ) throws(ObjectViewError) -> ObservationAdmission {
        try validate(session)
        guard observation.profile == profile else {
            throw ObjectViewError(.profileMismatch)
        }
        guard var bucket = buckets[observation.objectID] else {
            throw ObjectViewError(.unwatchedObjectID)
        }
        guard observation.bytes.count <= ObjectViewConfiguration.maximumObjectBytes else {
            throw ObjectViewError(.objectBytesExceedCapacity)
        }
        let objectType = try validatedObjectType(for: observation)

        let incoming = ObjectCandidate(
            source: observation.source,
            delivery: observation.delivery,
            revision: observation.revision,
            observedAtTick: tick,
            profile: observation.profile,
            objectType: objectType,
            bytes: observation.bytes
        )

        if let incomingRevision = observation.revision {
            for candidate in bucket.candidates {
                guard candidate.source == observation.source,
                      let existingRevision = candidate.revision,
                      existingRevision.domain == incomingRevision.domain else {
                    continue
                }
                if existingRevision.value > incomingRevision.value {
                    return .rejectedOutdatedRevision
                }
            }
        }

        var working: [ObjectCandidate] = []
        var removed = 0
        if let incomingRevision = observation.revision {
            for candidate in bucket.candidates {
                if candidate.source == observation.source,
                   let existingRevision = candidate.revision,
                   existingRevision.domain == incomingRevision.domain,
                   existingRevision.value < incomingRevision.value {
                    removed += 1
                    continue
                }
                working.append(candidate)
            }
        } else {
            working = bucket.candidates
        }

        if let index = working.firstIndex(where: { candidate in
            candidate.source == observation.source
                && candidate.revision == observation.revision
                && candidate.bytes == observation.bytes
        }) {
            let existing = working[index]
            working[index] = ObjectCandidate(
                source: existing.source,
                delivery: observation.delivery == .resolve ? .resolve : existing.delivery,
                revision: existing.revision,
                observedAtTick: max(existing.observedAtTick, tick),
                profile: existing.profile,
                objectType: existing.objectType,
                bytes: existing.bytes
            )
            bucket.candidates = working
            bucket.hadConflict = bucket.hadConflict || working.count > 1
            buckets[observation.objectID] = bucket
            return removed > 0 ? .superseded(removedCandidates: removed) : .coalesced
        }

        working.append(incoming)
        guard working.count <= ObjectViewConfiguration.maximumCandidatesPerObject else {
            bucket.capacitySaturated = true
            buckets[observation.objectID] = bucket
            return .rejectedCapacity
        }

        bucket.candidates = working
        bucket.hadConflict = bucket.hadConflict || working.count > 1
        buckets[observation.objectID] = bucket
        return removed > 0 ? .superseded(removedCandidates: removed) : .admitted
    }

    /// Removes one source's Advertise candidates for a watched identifier.
    ///
    /// Candidates reported in a Resolve or received from other sources stay
    /// visible.
    ///
    /// - Parameters:
    ///   - source: The source that withdrew its evidence.
    ///   - objectID: The watched identifier.
    ///   - session: The current attachment session.
    /// - Returns: The number of removed candidates.
    /// - Throws: ``ObjectViewError`` for a replaced session or unwatched
    ///   identifier.
    @discardableResult
    public mutating func withdraw(
        source: ObjectSource,
        for objectID: ObjectID,
        in session: ObservationSession
    ) throws(ObjectViewError) -> Int {
        try validate(session)
        guard var bucket = buckets[objectID] else {
            throw ObjectViewError(.unwatchedObjectID)
        }
        let before = bucket.candidates.count
        bucket.candidates.removeAll { $0.source == source && $0.delivery == .advertise }
        buckets[objectID] = bucket
        return before - bucket.candidates.count
    }

    /// Records a gap or reset for the current attachment.
    ///
    /// Retained evidence is preserved and every snapshot exposes
    /// ``ObjectUncertainty/continuityLoss``. A replacement session clears the
    /// fact.
    ///
    /// - Parameter session: The current attachment session.
    /// - Throws: ``ObjectViewError/Reason/staleSession`` when the session was
    ///   replaced.
    public mutating func recordContinuityLoss(
        in session: ObservationSession
    ) throws(ObjectViewError) {
        try validate(session)
        continuityLost = true
    }

    /// Records a source's Deadvertise from an independently drained stream.
    ///
    /// Retains advertised bytes with uncertainty because the host streams
    /// cannot order Advertise relative to Deadvertise. Correlated Resolve
    /// evidence and claims from other reporters retain their provenance.
    ///
    /// - Parameters:
    ///   - event: A normalized Deadvertise from the attached runtime.
    ///   - session: The current attachment session.
    /// - Returns: The number of watched identifiers named in the event.
    /// - Throws: A stale session, malformed event, or reporter saturation
    ///   error. A rejected event changes no per-object withdrawal records.
    @discardableResult
    public mutating func noteDeadvertise(
        _ event: RuntimeEventValue, in session: ObservationSession
    ) throws(ObjectViewError) -> Int {
        try validate(session)
        guard event.family == .deadvertise else { throw ObjectViewError(.invalidEventPayload) }
        let source = ObjectSource(rawValue: event.context.sourceID)
        var ids: Set<ObjectID> = []
        do throws(WireDecodeError) {
            try visitDeadvertisedIDs(in: event.value, profile: profile) { uuid in
                let id = ObjectID(uuid: uuid)
                if buckets[id] != nil { ids.insert(id) }
            }
        } catch {
            throw ObjectViewError(.invalidEventPayload)
        }
        let saturated = ids.filter { id in
            guard let bucket = buckets[id] else { return false }
            return bucket.withdrawnSources.count >= ObjectViewConfiguration.maximumCandidatesPerObject
                && !bucket.withdrawnSources.contains(source)
        }
        if !saturated.isEmpty {
            for id in saturated { buckets[id]?.capacitySaturated = true }
            throw ObjectViewError(.withdrawalCapacityExceeded)
        }
        for id in ids { buckets[id]?.withdrawnSources.insert(source) }
        return ids.count
    }

    /// Releases candidates that reached the retention boundary.
    ///
    /// This is optional maintenance. ``snapshot(for:at:)`` already hides
    /// retained bytes at the same boundary without mutating the view.
    ///
    /// - Parameter tick: The explicit monotonic tick.
    public mutating func expire(at tick: ObjectViewTick) {
        for objectID in Array(buckets.keys) {
            guard var bucket = buckets[objectID] else { continue }
            let remaining = bucket.candidates.filter {
                age(of: $0, at: tick) < configuration.retainForTicks
            }
            if remaining.count != bucket.candidates.count {
                bucket.candidates = remaining
                bucket.expiredPreviously = true
            }
            buckets[objectID] = bucket
        }
    }

    /// Returns an owned snapshot for one watched identifier.
    ///
    /// Bytes at or beyond the retention boundary are hidden even when
    /// ``expire(at:)`` was never called. An identifier outside the fixed list
    /// returns ``ObjectEvidence/unobserved``.
    ///
    /// - Parameters:
    ///   - objectID: The watched identifier.
    ///   - tick: The explicit monotonic tick.
    /// - Returns: The read-only projection at `tick`.
    public func snapshot(
        for objectID: ObjectID,
        at tick: ObjectViewTick
    ) -> ObjectSnapshot {
        guard let bucket = buckets[objectID] else {
            return ObjectSnapshot(
                objectID: objectID,
                evidence: .unobserved,
                freshness: .unobserved,
                uncertainty: [],
                ageTicks: nil
            )
        }

        var visible: [ObjectCandidate] = []
        var hiddenCount = 0
        var newestAge: ObjectViewTick?
        for candidate in bucket.candidates {
            let candidateAge = age(of: candidate, at: tick)
            newestAge = min(newestAge ?? candidateAge, candidateAge)
            if candidateAge >= configuration.retainForTicks {
                hiddenCount += 1
            } else {
                visible.append(candidate)
            }
        }

        var uncertainty = ObjectUncertainty(rawValue: 0)
        if bucket.capacitySaturated { uncertainty.insert(.capacitySaturation) }
        if continuityLost { uncertainty.insert(.continuityLoss) }
        if visible.isEmpty ? !bucket.withdrawnSources.isEmpty : visible.contains(where: {
            $0.delivery == .advertise && bucket.withdrawnSources.contains($0.source)
        }) {
            uncertainty.insert(.withdrawalObserved)
        }
        if bucket.hadConflict && (hiddenCount > 0 || bucket.expiredPreviously) {
            uncertainty.insert(.conflictEvidenceExpired)
        }

        let evidence: ObjectEvidence
        let freshness: ObjectFreshness
        if visible.isEmpty {
            if bucket.candidates.isEmpty && !bucket.expiredPreviously {
                evidence = .unobserved
                freshness = .unobserved
            } else {
                evidence = .expired
                freshness = .expired
            }
        } else {
            if visible.count == 1 {
                evidence = .observed(visible[0])
            } else {
                evidence = .conflicting(visible)
            }
            freshness = (newestAge ?? 0) >= configuration.staleAfterTicks ? .stale : .fresh
        }

        return ObjectSnapshot(
            objectID: objectID,
            evidence: evidence,
            freshness: freshness,
            uncertainty: uncertainty,
            ageTicks: newestAge
        )
    }

    private func validate(_ session: ObservationSession) throws(ObjectViewError) {
        guard session === self.session else {
            throw ObjectViewError(.staleSession)
        }
    }

    private func age(
        of candidate: ObjectCandidate,
        at tick: ObjectViewTick
    ) -> ObjectViewTick {
        tick > candidate.observedAtTick ? tick - candidate.observedAtTick : 0
    }

    private func validatedObjectType(
        for observation: ObjectObservation
    ) throws(ObjectViewError) -> ObjectType {
        var identified: ObjectType?
        var failure: ObjectViewError?
        observation.bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else {
                failure = ObjectViewError(.invalidObjectBytes)
                return
            }
            let slice = ByteSlice(bytes: base, length: buffer.count)
            do {
                switch observation.profile {
                case .coaty3JSON:
                    let object = try DynamicObject(decoding: slice)
                    try object.withEncodedBytes { encoded in
                        identified = try Self.objectType(
                            decoding: encoded,
                            profile: .coaty3JSON,
                            expected: observation.objectID
                        )
                    }
                case .axoloty1CBOR:
                    let object = try BoundedCBORObject<2048, 24>(decoding: slice)
                    try object.withEncodedBytes { encoded in
                        identified = try Self.objectType(
                            decoding: encoded,
                            profile: .axoloty1CBOR,
                            expected: observation.objectID
                        )
                    }
                }
            } catch let error as ObjectViewError {
                failure = error
            } catch {
                failure = ObjectViewError(.invalidObjectBytes)
            }
        }
        if let failure { throw failure }
        guard let identified else { throw ObjectViewError(.invalidObjectBytes) }
        return identified
    }

    private static func objectType(
        decoding bytes: ByteSlice,
        profile: WireProfile,
        expected: ObjectID
    ) throws(ObjectViewError) -> ObjectType {
        var result: ObjectType?
        var failure: ObjectViewError?
        bytes.withBytes { pointer, count in
            let reader = WireCodec(profile: profile).reader(
                bytes: pointer.assumingMemoryBound(to: UInt8.self),
                length: count
            )
            do throws(WireDecodeError) {
                try reader.validate()
            } catch {
                failure = ObjectViewError(.invalidObjectBytes)
                return
            }
            guard let uuid = reader.readUUID("objectId"),
                  let typeBytes = reader.readString("objectType"),
                  typeBytes.length > 0,
                  let type = ObjectType(bytes: typeBytes) else {
                failure = ObjectViewError(.invalidObjectBytes)
                return
            }
            guard ObjectID(uuid: uuid) == expected else {
                failure = ObjectViewError(.objectIdentityMismatch)
                return
            }
            result = type
        }
        if let failure { throw failure }
        guard let result else { throw ObjectViewError(.invalidObjectBytes) }
        return result
    }
}
