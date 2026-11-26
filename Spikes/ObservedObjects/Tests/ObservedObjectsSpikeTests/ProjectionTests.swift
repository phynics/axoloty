// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyWire
import ObservedObjectsSpike
import Testing

private enum Fixture {
    static let pumpText = "11111111-1111-4111-8111-111111111111"
    static let pumpID = ObjectID(uuid: UUID16(parsing: "11111111-1111-4111-8111-111111111111")!)
    static let otherText = "22222222-2222-4222-8222-222222222222"
    static let otherID = ObjectID(uuid: UUID16(parsing: "22222222-2222-4222-8222-222222222222")!)
    static let sourceOne = ObjectSource(rawValue: syntheticID(1).uuid)
    static let sourceTwo = ObjectSource(rawValue: syntheticID(2).uuid)
    static let sourceThree = ObjectSource(rawValue: syntheticID(3).uuid)
}

private struct PumpReading: ObjectSchema, Equatable {
    let reading: Int

    static let schema: PortableObjectSchema<PumpReading> = {
        var fields = InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
        fields[0] = ObjectFieldDescriptor(
            key: ObjectFieldKey("reading")!,
            index: 0,
            flags: .required
        )
        return PortableObjectSchema(
            objectType: ObjectType("Pump")!,
            coreType: .coatyObject,
            fieldCount: 1,
            fields: fields
        )
    }()

    init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
        reading = try fields.decode("reading", as: Int.self)
    }

    borrowing func encodeFields<let editorCapacity: Int>(
        to encoder: inout ObjectFieldEncoder<editorCapacity>
    ) throws(ObjectEncodingError) {
        do {
            try encoder.setInteger(reading, forKey: "reading")
        } catch {
            throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField
        }
    }
}

private func pumpJSON(id: String, reading: Int, schemaVersion: Int = 1) -> [UInt8] {
    let text = """
    {"objectId":"\(id)","objectType":"Pump","name":"Pump A","coreType":"CoatyObject",\
    "schemaVersion":\(schemaVersion),"reading":\(reading),\
    "vendorMetadata":{"nested":true,"unknown":"kept"},"sampleLexeme":1.50}
    """
    return Array(text.utf8)
}

private func readPump(_ candidate: ObjectCandidate) throws(ObjectViewError) -> PumpReading? {
    let version = candidate.bytes.withUnsafeBufferPointer { buffer -> Int? in
        guard let base = buffer.baseAddress else { return nil }
        let reader = WireCodec(profile: candidate.profile).reader(bytes: base, length: buffer.count)
        return reader.readInt("schemaVersion")
    }
    guard version == 1 else { return nil }
    return try candidate.decode(PumpReading.self)
}

private func pumpCBOR(id: String) -> [UInt8] {
    var bytes: [UInt8] = [0xA5]
    bytes += [0x64] + Array("name".utf8) + [0x64] + Array("Pump".utf8)
    bytes += [0x67] + Array("reading".utf8) + [0x18, 0x2A]
    bytes += [0x68] + Array("coreType".utf8) + [0x6B] + Array("CoatyObject".utf8)
    let identifier = Array(id.utf8)
    bytes += [0x68] + Array("objectId".utf8) + [0x78, UInt8(identifier.count)] + identifier
    bytes += [0x6A] + Array("objectType".utf8) + [0x64] + Array("Pump".utf8)
    return bytes
}

private func observation(
    id: ObjectID,
    source: ObjectSource,
    revision: Int64?,
    bytes: [UInt8],
    delivery: ObjectDeliveryKind = .advertise,
    profile: WireProfile = .coaty3JSON
) -> ObjectObservation {
    ObjectObservation(
        objectID: id,
        source: source,
        delivery: delivery,
        profile: profile,
        revision: revision.map { ObjectRevision(value: $0) },
        bytes: bytes
    )
}

private func configuration(
    staleAfter: ObjectViewTick,
    retainFor: ObjectViewTick
) throws(ObjectViewError) -> ObjectViewConfiguration {
    try ObjectViewConfiguration(
        staleAfterTicks: staleAfter,
        retainForTicks: retainFor
    )
}

private func syntheticID(_ value: UInt8) -> ObjectID {
    ObjectID(uuid: UUID16(bytes: (
        value, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )))
}

@Suite("Observed object projection")
struct ProjectionTests {
    @Test("Admits exact bytes and decodes a manual schema")
    func admitsExactBytesAndManualSchema() throws {
        let payload = pumpJSON(id: Fixture.pumpText, reading: 42)
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 10, retainFor: 20)
        )
        let session = view.beginSession()

        let admission = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 1,
                bytes: payload
            ),
            in: session,
            observedAt: 100
        )
        #expect(admission == .admitted)

        let snapshot = view.snapshot(for: Fixture.pumpID, at: 103)
        #expect(snapshot.freshness == .fresh)
        #expect(snapshot.ageTicks == 3)
        #expect(snapshot.uncertainty.isEmpty)

        guard case .observed(let candidate) = snapshot.evidence else {
            Issue.record("expected one observed candidate")
            return
        }
        #expect(candidate.bytes == payload)
        #expect(candidate.profile == .coaty3JSON)
        #expect(candidate.objectType.equals("Pump"))
        #expect(candidate.revision?.value == 1)
        let decoded = try readPump(candidate)
        #expect(decoded?.reading == 42)

        let text = String(decoding: candidate.bytes, as: UTF8.self)
        #expect(text.contains("\"vendorMetadata\":{\"nested\":true,\"unknown\":\"kept\"}"))
        #expect(text.contains("\"sampleLexeme\":1.50"))
    }

    @Test("A newer same-source revision supersedes an older candidate")
    func newerRevisionSupersedes() throws {
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 10, retainFor: 20)
        )
        let session = view.beginSession()
        let old = pumpJSON(id: Fixture.pumpText, reading: 1)
        let new = pumpJSON(id: Fixture.pumpText, reading: 2)

        let first = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 1,
                bytes: old
            ),
            in: session,
            observedAt: 100
        )
        #expect(first == .admitted)

        let second = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 2,
                bytes: new
            ),
            in: session,
            observedAt: 101
        )
        #expect(second == .superseded(removedCandidates: 1))

        guard case .observed(let candidate) = view.snapshot(
            for: Fixture.pumpID,
            at: 101
        ).evidence else {
            Issue.record("expected one observed candidate")
            return
        }
        #expect(candidate.bytes == new)
        #expect(candidate.revision?.value == 2)
    }

    @Test("An older revision cannot refresh or replace retained evidence")
    func olderRevisionCannotRefresh() throws {
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 3, retainFor: 10)
        )
        let session = view.beginSession()
        let newer = pumpJSON(id: Fixture.pumpText, reading: 20)
        let older = pumpJSON(id: Fixture.pumpText, reading: 10)

        _ = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 2,
                bytes: newer
            ),
            in: session,
            observedAt: 100
        )

        let admission = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 1,
                bytes: older
            ),
            in: session,
            observedAt: 105
        )
        #expect(admission == .rejectedOutdatedRevision)

        let snapshot = view.snapshot(for: Fixture.pumpID, at: 105)
        #expect(snapshot.freshness == .stale)
        #expect(snapshot.ageTicks == 5)
        guard case .observed(let candidate) = snapshot.evidence else {
            Issue.record("expected retained newer candidate")
            return
        }
        #expect(candidate.bytes == newer)
        #expect(candidate.observedAtTick == 100)
        #expect(candidate.revision?.value == 2)
    }

    @Test("Equal divergent revisions from one source remain visible")
    func equalRevisionDivergenceRemainsVisible() throws {
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 10, retainFor: 20)
        )
        let session = view.beginSession()

        _ = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 7,
                bytes: pumpJSON(id: Fixture.pumpText, reading: 1)
            ),
            in: session,
            observedAt: 100
        )
        let admission = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 7,
                bytes: pumpJSON(id: Fixture.pumpText, reading: 2)
            ),
            in: session,
            observedAt: 101
        )
        #expect(admission == .admitted)

        guard case .conflicting(let candidates) = view.snapshot(
            for: Fixture.pumpID,
            at: 101
        ).evidence else {
            Issue.record("expected a conflict")
            return
        }
        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.source == Fixture.sourceOne })
        #expect(candidates.allSatisfy { $0.revision?.value == 7 })
    }

    @Test("Incomparable same-source revision domains remain visible")
    func incomparableRevisionDomainsRemainVisible() throws {
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 10, retainFor: 20)
        )
        let session = view.beginSession()

        _ = try view.apply(
            ObjectObservation(
                objectID: Fixture.pumpID,
                source: Fixture.sourceOne,
                delivery: .advertise,
                profile: .coaty3JSON,
                revision: ObjectRevision(
                    domain: RevisionDomain(rawValue: 1),
                    value: 1
                ),
                bytes: pumpJSON(id: Fixture.pumpText, reading: 1)
            ),
            in: session,
            observedAt: 100
        )
        _ = try view.apply(
            ObjectObservation(
                objectID: Fixture.pumpID,
                source: Fixture.sourceOne,
                delivery: .advertise,
                profile: .coaty3JSON,
                revision: ObjectRevision(
                    domain: RevisionDomain(rawValue: 2),
                    value: 2
                ),
                bytes: pumpJSON(id: Fixture.pumpText, reading: 2)
            ),
            in: session,
            observedAt: 101
        )

        guard case .conflicting(let candidates) = view.snapshot(
            for: Fixture.pumpID,
            at: 101
        ).evidence else {
            Issue.record("expected incomparable claims to remain visible")
            return
        }
        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.source == Fixture.sourceOne })
    }

    @Test("Cross-source claims remain visible")
    func crossSourceClaimsRemainVisible() throws {
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 10, retainFor: 20)
        )
        let session = view.beginSession()

        _ = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: nil,
                bytes: pumpJSON(id: Fixture.pumpText, reading: 1)
            ),
            in: session,
            observedAt: 100
        )
        _ = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceTwo,
                revision: nil,
                bytes: pumpJSON(id: Fixture.pumpText, reading: 2)
            ),
            in: session,
            observedAt: 101
        )

        guard case .conflicting(let candidates) = view.snapshot(
            for: Fixture.pumpID,
            at: 101
        ).evidence else {
            Issue.record("expected a cross-source conflict")
            return
        }
        #expect(candidates.count == 2)
        #expect(Set(candidates.map(\.source)) == Set([Fixture.sourceOne, Fixture.sourceTwo]))
    }

    @Test("Capacity plus one preserves admitted payloads and reports uncertainty")
    func capacityPlusOnePreservesAdmittedPayloads() throws {
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 10, retainFor: 20)
        )
        let session = view.beginSession()

        _ = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 1,
                bytes: pumpJSON(id: Fixture.pumpText, reading: 1)
            ),
            in: session,
            observedAt: 100
        )
        _ = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceTwo,
                revision: 1,
                bytes: pumpJSON(id: Fixture.pumpText, reading: 2)
            ),
            in: session,
            observedAt: 101
        )
        let overflow = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceThree,
                revision: 1,
                bytes: pumpJSON(id: Fixture.pumpText, reading: 3)
            ),
            in: session,
            observedAt: 102
        )
        #expect(overflow == .rejectedCapacity)

        let snapshot = view.snapshot(for: Fixture.pumpID, at: 102)
        #expect(snapshot.uncertainty.contains(.capacitySaturation))
        guard case .conflicting(let candidates) = snapshot.evidence else {
            Issue.record("expected the two admitted payloads to remain visible")
            return
        }
        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.source != Fixture.sourceThree })
    }

    @Test("Reads hide bytes at retention without maintenance")
    func readsHideBytesAtRetention() throws {
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 2, retainFor: 5)
        )
        let session = view.beginSession()
        _ = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 1,
                bytes: pumpJSON(id: Fixture.pumpText, reading: 1)
            ),
            in: session,
            observedAt: 100
        )

        let fresh = view.snapshot(for: Fixture.pumpID, at: 101)
        #expect(fresh.freshness == .fresh)
        #expect(fresh.evidence != .expired)

        let stale = view.snapshot(for: Fixture.pumpID, at: 102)
        #expect(stale.freshness == .stale)
        guard case .observed = stale.evidence else {
            Issue.record("stale bytes must remain visible before retention")
            return
        }

        let expired = view.snapshot(for: Fixture.pumpID, at: 105)
        #expect(expired.freshness == .expired)
        #expect(expired.evidence == .expired)
        #expect(expired.ageTicks == 5)

        view.expire(at: 105)
        let afterMaintenance = view.snapshot(for: Fixture.pumpID, at: 105)
        #expect(afterMaintenance.evidence == .expired)
    }

    @Test("Expiration preserves conflict evidence")
    func expirationPreservesConflictEvidence() throws {
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 2, retainFor: 4)
        )
        let session = view.beginSession()

        _ = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 1,
                bytes: pumpJSON(id: Fixture.pumpText, reading: 1)
            ),
            in: session,
            observedAt: 100
        )
        _ = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceTwo,
                revision: 1,
                bytes: pumpJSON(id: Fixture.pumpText, reading: 2)
            ),
            in: session,
            observedAt: 100
        )

        let expired = view.snapshot(for: Fixture.pumpID, at: 104)
        #expect(expired.evidence == .expired)
        #expect(expired.uncertainty.contains(.conflictEvidenceExpired))

        view.expire(at: 104)
        let maintained = view.snapshot(for: Fixture.pumpID, at: 104)
        #expect(maintained.evidence == .expired)
        #expect(maintained.uncertainty.contains(.conflictEvidenceExpired))
    }

    @Test("Exact duplicate bytes from one source coalesce")
    func duplicateEvidenceCoalesces() throws {
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 10, retainFor: 20)
        )
        let session = view.beginSession()
        let payload = pumpJSON(id: Fixture.pumpText, reading: 4)

        _ = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 3,
                bytes: payload
            ),
            in: session,
            observedAt: 100
        )
        let second = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 3,
                bytes: payload
            ),
            in: session,
            observedAt: 102
        )
        #expect(second == .coalesced)

        guard case .observed(let candidate) = view.snapshot(
            for: Fixture.pumpID,
            at: 103
        ).evidence else {
            Issue.record("expected one coalesced candidate")
            return
        }
        #expect(candidate.observedAtTick == 102)
        #expect(candidate.bytes == payload)
        #expect(view.snapshot(for: Fixture.pumpID, at: 103).ageTicks == 1)
    }

    @Test("Replacing a session rejects old tokens and clears evidence")
    func sessionReplacementRejectsOldTokens() throws {
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 10, retainFor: 20)
        )
        let first = view.beginSession()
        _ = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 1,
                bytes: pumpJSON(id: Fixture.pumpText, reading: 1)
            ),
            in: first,
            observedAt: 100
        )

        let second = view.beginSession()
        #expect(view.snapshot(for: Fixture.pumpID, at: 100).evidence == .unobserved)

        do {
            _ = try view.apply(
                observation(
                    id: Fixture.pumpID,
                    source: Fixture.sourceOne,
                    revision: 2,
                    bytes: pumpJSON(id: Fixture.pumpText, reading: 2)
                ),
                in: first,
                observedAt: 101
            )
            Issue.record("expected a stale session rejection")
        } catch {
            #expect(error.reason == .staleSession)
        }

        let admission = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 2,
                bytes: pumpJSON(id: Fixture.pumpText, reading: 2)
            ),
            in: second,
            observedAt: 101
        )
        #expect(admission == .admitted)
    }

    @Test("Continuity loss preserves evidence with uncertainty")
    func continuityLossPreservesEvidence() throws {
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 10, retainFor: 20)
        )
        let session = view.beginSession()
        let payload = pumpJSON(id: Fixture.pumpText, reading: 8)
        _ = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 1,
                bytes: payload
            ),
            in: session,
            observedAt: 100
        )

        try view.recordContinuityLoss(in: session)
        let snapshot = view.snapshot(for: Fixture.pumpID, at: 101)
        #expect(snapshot.uncertainty.contains(.continuityLoss))
        guard case .observed(let candidate) = snapshot.evidence else {
            Issue.record("continuity loss must preserve retained bytes")
            return
        }
        #expect(candidate.bytes == payload)

        _ = view.beginSession()
        let replaced = view.snapshot(for: Fixture.pumpID, at: 101)
        #expect(replaced.evidence == .unobserved)
        #expect(replaced.uncertainty.isEmpty)
    }

    @Test("A withdrawal removes only the named source's advertisement", arguments: [false, true])
    func withdrawalPreservesOtherEvidence(sameReporter: Bool) throws {
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 10, retainFor: 20)
        )
        let session = view.beginSession()
        let retainedSource = sameReporter ? Fixture.sourceOne : Fixture.sourceTwo
        let retainedDelivery: ObjectDeliveryKind = sameReporter ? .resolve : .advertise
        _ = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 1,
                bytes: pumpJSON(id: Fixture.pumpText, reading: 1)
            ),
            in: session,
            observedAt: 100
        )
        _ = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: retainedSource,
                revision: 1,
                bytes: pumpJSON(id: Fixture.pumpText, reading: 2),
                delivery: retainedDelivery
            ),
            in: session,
            observedAt: 100
        )

        let removed = try view.withdraw(
            source: Fixture.sourceOne,
            for: Fixture.pumpID,
            in: session
        )
        #expect(removed == 1)

        guard case .observed(let candidate) = view.snapshot(
            for: Fixture.pumpID,
            at: 100
        ).evidence else {
            Issue.record("expected the unaffected candidate to remain")
            return
        }
        #expect(candidate.source == retainedSource)
        #expect(candidate.delivery == retainedDelivery)
    }

    @Test("Watched lists, policies, and byte ceilings are bounded")
    func boundsAreEnforced() throws {
        let tooMany = (0..<9).map { syntheticID(UInt8($0)) }
        #expect(throws: ObjectViewError.self) {
            _ = try ObjectView(
                watching: tooMany,
                configuration: configuration(staleAfter: 1, retainFor: 2)
            )
        }

        #expect(throws: ObjectViewError.self) {
            _ = try ObjectView(
                watching: [Fixture.pumpID, Fixture.pumpID],
                configuration: configuration(staleAfter: 1, retainFor: 2)
            )
        }

        #expect(throws: ObjectViewError.self) {
            _ = try ObjectViewConfiguration(staleAfterTicks: 5, retainForTicks: 4)
        }

        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 10, retainFor: 20)
        )
        let session = view.beginSession()
        #expect(throws: ObjectViewError.self) {
            _ = try view.apply(
                observation(
                    id: Fixture.pumpID,
                    source: Fixture.sourceOne,
                    revision: 1,
                    bytes: [UInt8](repeating: 0x20, count: 2049)
                ),
                in: session,
                observedAt: 100
            )
        }
    }

    @Test("Malformed, mismatched, and unwatched observations are rejected")
    func invalidObservationsAreRejected() throws {
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 10, retainFor: 20)
        )
        let session = view.beginSession()

        do {
            _ = try view.apply(
                observation(
                    id: Fixture.pumpID,
                    source: Fixture.sourceOne,
                    revision: 1,
                    bytes: Array("{not json".utf8)
                ),
                in: session,
                observedAt: 100
            )
            Issue.record("expected malformed bytes to be rejected")
        } catch {
            #expect(error.reason == .invalidObjectBytes)
        }

        do {
            _ = try view.apply(
                observation(
                    id: Fixture.pumpID,
                    source: Fixture.sourceOne,
                    revision: 1,
                    bytes: pumpJSON(id: Fixture.otherText, reading: 1)
                ),
                in: session,
                observedAt: 100
            )
            Issue.record("expected a mismatched identity to be rejected")
        } catch {
            #expect(error.reason == .objectIdentityMismatch)
        }

        do {
            _ = try view.apply(
                observation(
                    id: Fixture.otherID,
                    source: Fixture.sourceOne,
                    revision: 1,
                    bytes: pumpJSON(id: Fixture.otherText, reading: 1)
                ),
                in: session,
                observedAt: 100
            )
            Issue.record("expected an unwatched identity to be rejected")
        } catch {
            #expect(error.reason == .unwatchedObjectID)
        }
    }

    @Test("A small CBOR fixture retains exact bytes")
    func smallCBORFixtureRetainsExactBytes() throws {
        let payload = pumpCBOR(id: Fixture.pumpText)
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 10, retainFor: 20),
            profile: .axoloty1CBOR
        )
        let session = view.beginSession()

        let admission = try view.apply(
            observation(
                id: Fixture.pumpID,
                source: Fixture.sourceOne,
                revision: 1,
                bytes: payload,
                delivery: .resolve,
                profile: .axoloty1CBOR
            ),
            in: session,
            observedAt: 100
        )
        #expect(admission == .admitted)

        guard case .observed(let candidate) = view.snapshot(
            for: Fixture.pumpID,
            at: 100
        ).evidence else {
            Issue.record("expected one observed CBOR candidate")
            return
        }
        #expect(candidate.bytes == payload)
        #expect(candidate.profile == .axoloty1CBOR)
        #expect(candidate.delivery == .resolve)
        #expect(candidate.objectType.equals("Pump"))

        do {
            _ = try candidate.decode(PumpReading.self)
            Issue.record("expected a JSON-only typed projection rejection")
        } catch {
            #expect(error.reason == .unsupportedTypedProjection)
        }
    }

    @Test func separateViewsRejectEachOthersSessions() throws {
        let policy = try configuration(staleAfter: 10, retainFor: 20)
        var first = try ObjectView(watching: [Fixture.pumpID], configuration: policy)
        var second = try ObjectView(watching: [Fixture.pumpID], configuration: policy)
        let firstSession = first.beginSession()
        _ = second.beginSession()

        #expect(throws: ObjectViewError(.staleSession)) {
            try second.recordContinuityLoss(in: firstSession)
        }
    }

    @Test func unknownSchemaVersionKeepsDynamicBytes() throws {
        let payload = pumpJSON(id: Fixture.pumpText, reading: 42, schemaVersion: 2)
        var view = try ObjectView(
            watching: [Fixture.pumpID],
            configuration: configuration(staleAfter: 10, retainFor: 20)
        )
        let session = view.beginSession()
        let sample = observation(id: Fixture.pumpID, source: Fixture.sourceOne, revision: nil, bytes: payload)
        try view.apply(sample, in: session, observedAt: 100)

        guard case .observed(let candidate) = view.snapshot(for: Fixture.pumpID, at: 100).evidence else {
            Issue.record("expected retained evidence")
            return
        }
        let decoded = try readPump(candidate)
        #expect(decoded == nil)
        #expect(candidate.bytes == payload)
    }
}
