// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Synchronization
import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

private func waitForPresence(
    _ phase: String,
    until condition: @escaping @Sendable () async -> Bool
) async throws {
    try await withTimeout(phase, timeout: .seconds(5)) {
        while !(await condition()) {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

private final class PresenceTestClock: Sendable {
    private struct Sleeper {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var nowMS: UInt64
        var sleeper: Sleeper?
        var sleepRequests = 0
    }

    private let state: Mutex<State>

    init(nowMS: UInt64 = 0) {
        state = Mutex(State(nowMS: nowMS))
    }

    var clock: RuntimePresenceClock {
        RuntimePresenceClock(nowMS: { self.state.withLock { $0.nowMS } }, sleepUntilMS: sleep(until:))
    }

    var sleepingUntil: UInt64? { state.withLock { $0.sleeper?.deadline } }
    var sleepRequests: Int { state.withLock { $0.sleepRequests } }

    func advance(to now: UInt64) {
        let woken = state.withLock { state -> Sleeper? in
            precondition(now >= state.nowMS)
            state.nowMS = now
            guard let sleeper = state.sleeper, sleeper.deadline <= now else { return nil }
            state.sleeper = nil
            return sleeper
        }
        woken?.continuation.resume()
    }

    func tick(at now: UInt64) async throws {
        advance(to: now)
        try await waitForPresence("presence tick at \(now) ms to finish") {
            // The next sleep is installed only after the executor has
            // completed the expiry and refresh passes for this time.
            self.sleepingUntil.map { $0 > now } ?? false
        }
    }

    private func sleep(until deadline: UInt64) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let suspended = state.withLock { state in
                    guard !Task.isCancelled else { return false }
                    state.sleepRequests += 1
                    guard deadline > state.nowMS else { return false }
                    precondition(state.sleeper == nil)
                    state.sleeper = Sleeper(deadline: deadline, continuation: continuation)
                    return true
                }
                if !suspended { continuation.resume() }
            }
        } onCancel: {
            let cancelled = self.state.withLock { state in
                let sleeper = state.sleeper
                state.sleeper = nil
                return sleeper
            }
            cancelled?.continuation.resume()
        }
    }
}

private func presenceBuilder(capacities: RuntimeCapacities? = nil) throws(AxolotyError) -> RuntimeBuilder {
    try RuntimeBuilder(sourceID: .zero, namespace: "presence", capacities: capacities, presence: try RuntimePresenceConfiguration())
}

private func presenceObject(_ objectID: UUID16, name: String = "host-presence") throws(WireEncodeError) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: 256)
    let length = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) -> Int in
        var writer = WireCodec(profile: .axoloty1CBOR).writer(buffer: buffer.baseAddress!, capacity: buffer.count)
        try writer.beginObject()
        try writer.writeUUIDField("objectId", objectID)
        try writer.writeComma()
        try presenceText(&writer, "coreType", "IoSource")
        try writer.writeComma()
        try presenceText(&writer, "objectType", "coaty.IoSource")
        try writer.writeComma()
        try presenceText(&writer, "name", name)
        try writer.endObject()
        return writer.position
    }
    return Array(output.prefix(length))
}

private func presenceText(_ writer: inout WireWriter, _ key: StaticString, _ value: String) throws(WireEncodeError) {
    try Array(value.utf8).withUnsafeBufferPointer { buffer throws(WireEncodeError) in
        try writer.writeStringField(key, ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
    }
}

private func presenceAdvertiseFrame(_ peer: UUID16, nowMS: UInt32 = 7) throws -> RuntimeInboundFrame {
    let object = try presenceObject(peer)
    let payload = try RuntimeWirePayload.advertiseEnvelope(
        object: object, leaseMS: 1_000, ownerEpoch: 1, profile: .axoloty1CBOR
    )
    return .profile(route: try presenceRoute(.advertise, sourceID: peer), payload: payload, nowMS: nowMS)
}

private func presenceRoute(_ capability: ProtocolCapability, sourceID: UUID16) throws -> String {
    try CoatyRoute.route(
        for: ProtocolRoutingKey(capability: capability, sourceID: sourceID), namespace: "presence", profile: .axoloty1CBOR
    )
}

private func presenceDeadvertise(_ objectID: UUID16) throws(ProtocolError) -> [UInt8] {
    try RuntimeWirePayload.deadvertise(uuid: objectID, profile: .axoloty1CBOR)
}

private func advertisePublications(_ transport: TestTransport) async -> [RuntimeOutboundMessage] {
    await transport.publications().filter { isAdvertiseRoute($0.route) }
}

extension AxolotyRuntimeTests {
    private static let presencePeer = UUID16(parsing: "00000000-0000-4000-8000-000000000401")!
    private static let secondPresencePeer = UUID16(parsing: "00000000-0000-4000-8000-000000000402")!
    private static let thirdPresencePeer = UUID16(parsing: "00000000-0000-4000-8000-000000000403")!

    @Test("enabled host presence rejects coaty/3 before opening transport")
    func hostPresenceRequiresCBOR() async throws {
        let builder = try presenceBuilder()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)

        do {
            try await runtime.start()
            Issue.record("expected presence composition to fail")
        } catch let error as AxolotyError {
            guard case let .invalidConfiguration(option, reason) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(option == "presence")
            #expect(reason == "soft-state presence requires the axoloty/1 profile")
        }
        #expect(await transport.lifecycle.isEmpty)
        #expect(await runtime.state() == .initialized)
    }

    @Test("Core 1.0 builders retain disabled presence and legacy Advertise", arguments: [WireProfile.coaty3JSON, .axoloty1CBOR])
    func hostPresenceDisabledPreservesLegacyAdvertise(profile: WireProfile) async throws {
        let sourceBuilder = RuntimeBuilder.init(sourceID:namespace:identity:capacities:)
        let identityBuilder = RuntimeBuilder.init(identity:namespace:capacities:)
        let identity = try RuntimeIdentity(id: .zero, name: "legacy")
        let fromIdentity = try identityBuilder(identity, "presence", nil).finish()
        #expect(fromIdentity.presence == nil)
        let definition = try sourceBuilder(.zero, "presence", nil, nil).finish()
        #expect(definition.presence == nil)

        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: profile)
        let runtime = AxolotyRuntime(definition: definition, transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock))
        defer { await runtime.stop() }
        let expiries = await runtime.presenceExpiries()
        try await withTimeout("disabled presence stream to finish") {
            var iterator = expiries.makeAsyncIterator()
            #expect(await iterator.next() == nil)
        }
        let cborObject = try presenceObject(Self.presencePeer)
        #expect(await runtime.advertise(objectID: Self.presencePeer, object: cborObject, leaseMS: 1_000)
                == .rejected(.protocol(.unsupportedCapability)))

        try await runtime.start()
        let object = profile == .axoloty1CBOR ? cborObject : Array(
            #"{"objectId":"00000000-0000-4000-8000-000000000401","coreType":"IoSource","objectType":"coaty.IoSource","name":"legacy"}"#.utf8
        )
        let payload = try RuntimeWirePayload.advertiseEnvelope(
            object: object, leaseMS: 1_000, ownerEpoch: 1, profile: profile
        )
        if profile == .coaty3JSON {
            let legacy = try RuntimeWirePayload.advertiseEnvelope(object: object, profile: profile)
            #expect(legacy == payload)
        }
        #expect(await runtime.publish(.advertise(payload)) == .accepted)
        #expect(await runtime.publish(.advertise(payload)) == .rejected(.protocol(.duplicate)))
        try await waitForPresence("legacy Advertise publication") { await transport.sentCount() == 1 }
        clock.advance(to: 5_000)
        #expect(clock.sleepRequests == 0)
        #expect(await advertisePublications(transport).map(\.payload) == [payload])
    }

    @Test("leased admission validates running state, CBOR ID, lease, and envelope size")
    func hostLeasedAdvertiseValidatesIdentityAndEnvelopeCapacity() async throws {
        let peer = Self.presencePeer
        let object = try presenceObject(peer)
        let capacities = try RuntimeCapacities(protocolMaximumPayloadBytes: object.count)
        let definition = try presenceBuilder(capacities: capacities).finish()
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(definition: definition, transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock))
        defer { await runtime.stop() }
        #expect(await runtime.advertise(objectID: peer, object: object, leaseMS: 1_000) == .rejected(.notRunning(.stopped)))
        try await runtime.start()
        let before = await runtime.conformanceObservation().state

        #expect(await runtime.advertise(objectID: peer, object: object, leaseMS: 999) == .rejected(.malformedPayload))
        #expect(await runtime.advertise(objectID: peer, object: object, leaseMS: 3_600_001) == .rejected(.malformedPayload))
        #expect(await runtime.advertise(objectID: peer, object: [0xa0], leaseMS: 1_000) == .rejected(.malformedPayload))
        #expect(await runtime.advertise(objectID: Self.secondPresencePeer, object: object, leaseMS: 1_000)
                == .rejected(.malformedPayload))
        #expect(await runtime.advertise(objectID: peer, object: object, leaseMS: 1_000) == .rejected(.capacityExceeded))

        let after = await runtime.conformanceObservation()
        #expect(after.state == before)
        #expect(after.actions.isEmpty)
        #expect(await transport.sentCount() == 0)
    }

    @Test("leased admission leases the automatic identity and typed IO object IDs")
    func hostPresenceLeasesIdentityAndTypedIoAdvertisements() async throws {
        let identity = try RuntimeIdentity(id: .zero, name: "presence-owner")
        var builder = try RuntimeBuilder(identity: identity, namespace: "presence", presence: try RuntimePresenceConfiguration())
        let sourceJSON: StaticString = #"{"objectId":"00000000-0000-4000-8000-000000000401","objectType":"coaty.IoSource","name":"source","coreType":"IoSource","valueType":"com.example.Bool"}"#
        let endpoint = try builder.ioSource(
            metadata: try Object<IoSourceMetadata>(decoding: ByteSlice(
                bytes: sourceJSON.utf8Start, length: sourceJSON.utf8CodeUnitCount
            )),
            as: Bool.self
        )
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock))
        defer { await runtime.stop() }
        try await runtime.start()

        let advertisements = await advertisePublications(transport)
        #expect(advertisements.count == 2)
        let suffixes = advertisements.map { $0.route.split(separator: "/").last.map(String.init) }
        #expect(suffixes == [
            CoatyRoute.uuidString(identity.id).lowercased(),
            CoatyRoute.uuidString(endpoint.id.uuid).lowercased()
        ])
        var decodedObjectIDs: [UUID16] = []
        for advertisement in advertisements {
            let value = try advertisement.payload.withUnsafeBufferPointer { buffer throws(WireDecodeError) in
                let reader = WireCodec(profile: .axoloty1CBOR).reader(bytes: buffer.baseAddress!, length: buffer.count)
                return try AdvertiseWireData(from: reader)
            }
            #expect(value.leaseMS == 45_000)
            #expect(value.ownerEpoch != nil)
            decodedObjectIDs.append(
                value.object.ownedBytes().withUnsafeBufferPointer { buffer in
                    WireCodec(profile: .axoloty1CBOR).reader(bytes: buffer.baseAddress!, length: buffer.count).readUUID("objectId")
                } ?? .zero
            )
        }
        #expect(decodedObjectIDs == [identity.id, endpoint.id.uuid])

        for id in [identity.id, endpoint.id.uuid] {
            let object = try presenceObject(id)
            #expect(await runtime.advertise(objectID: id, object: object, leaseMS: 1_000)
                    == .rejected(.protocol(.duplicate)))
        }

        // The timer refreshes runtime-owned objects from the same table:
        // the IO endpoint phase is 717 ms and the identity phase is 2,933 ms.
        try await clock.tick(at: 750)
        try await waitForPresence("typed IO refresh") { await advertisePublications(transport).count == 3 }
        try await clock.tick(at: 3_000)
        try await waitForPresence("identity refresh") { await advertisePublications(transport).count == 4 }
        let refreshed = await advertisePublications(transport)
        #expect(try presenceAdvertisedObjectID(refreshed[2].payload) == endpoint.id.uuid)
        #expect(try presenceAdvertisedObjectID(refreshed[3].payload) == identity.id)
        let refreshSuffixes = refreshed[2...3].map { $0.route.split(separator: "/").last.map(String.init) }
        #expect(refreshSuffixes == [
            CoatyRoute.uuidString(endpoint.id.uuid).lowercased(),
            CoatyRoute.uuidString(identity.id).lowercased()
        ])
    }

    @Test("a foreign Deadvertise does not stop a runtime-owned IO lease")
    func hostForeignDeadvertiseKeepsRuntimeOwnedLease() async throws {
        let identity = try RuntimeIdentity(id: .zero, name: "presence-owner")
        var builder = try RuntimeBuilder(
            identity: identity,
            namespace: "presence",
            presence: try RuntimePresenceConfiguration()
        )
        let sourceJSON: StaticString = #"{"objectId":"00000000-0000-4000-8000-000000000401","objectType":"coaty.IoSource","name":"source","coreType":"IoSource","valueType":"com.example.Bool"}"#
        let endpoint = try builder.ioSource(
            metadata: try Object<IoSourceMetadata>(decoding: ByteSlice(
                bytes: sourceJSON.utf8Start, length: sourceJSON.utf8CodeUnitCount
            )),
            as: Bool.self
        )
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(
            definition: try builder.finish(),
            transport: transport,
            presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        defer { await runtime.stop() }
        try await runtime.start()

        let applicationObject = Self.secondPresencePeer
        try #require(await runtime.advertise(
            objectID: applicationObject,
            object: try presenceObject(applicationObject),
            leaseMS: 1_000
        ) == .accepted)
        try await waitForPresence("identity, IO, and application advertisements") {
            await advertisePublications(transport).count == 3
        }

        // The runtime source owns the application object but not the IO
        // endpoint. The accepted Deadvertise removes only the application
        // record, so the endpoint keeps refreshing.
        let withdrawal = try presenceMultiObjectDeadvertise(applicationObject, endpoint.id.uuid)
        #expect(await runtime.publish(.deadvertise(withdrawal)) == .accepted)
        try await clock.tick(at: 750)
        try await waitForPresence("IO refresh after a foreign Deadvertise") {
            await advertisePublications(transport).count == 4
        }
        let refreshed = await advertisePublications(transport)
        #expect(try presenceAdvertisedObjectID(refreshed[3].payload) == endpoint.id.uuid)
        #expect(
            refreshed[3].route.split(separator: "/").last.map(String.init)
                == CoatyRoute.uuidString(endpoint.id.uuid).lowercased()
        )
    }

    @Test("recovery re-announces runtime-owned leases and stop withdraws them once")
    func hostPresenceReconnectReannouncesRuntimeOwnedObjects() async throws {
        let identity = try RuntimeIdentity(id: .zero, name: "presence-owner")
        var builder = try RuntimeBuilder(
            identity: identity,
            namespace: "presence",
            presence: try RuntimePresenceConfiguration()
        )
        let sourceJSON: StaticString = #"{"objectId":"00000000-0000-4000-8000-000000000401","objectType":"coaty.IoSource","name":"source","coreType":"IoSource","valueType":"com.example.Bool"}"#
        let endpoint = try builder.ioSource(
            metadata: try Object<IoSourceMetadata>(decoding: ByteSlice(
                bytes: sourceJSON.utf8Start, length: sourceJSON.utf8CodeUnitCount
            )),
            as: Bool.self
        )
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(
            definition: try builder.finish(),
            transport: transport,
            presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        try await runtime.start()
        let initial = await advertisePublications(transport)
        #expect(initial.count == 2)

        await runtime.reconnect()
        #expect(await runtime.state() == .running)
        let recovered = await advertisePublications(transport)
        #expect(recovered.count == 4)
        #expect(Array(recovered.suffix(2)) == initial)

        // Recovery keeps the original 717 ms IO phase.
        try await clock.tick(at: 750)
        try await waitForPresence("IO refresh after recovery") { await advertisePublications(transport).count == 5 }

        await runtime.stop()
        let deadvertises = await transport.publications().filter { isDeadvertiseRoute($0.route) }
        #expect(deadvertises.map(\.payload) == [
            try presenceDeadvertise(endpoint.id.uuid),
            try presenceDeadvertise(identity.id)
        ])
    }

    @Test("identical declarations keep their phase and changed declarations reject atomically")
    func hostLeasedAdvertiseDeduplicatesAndRejectsAtomically() async throws {
        let capacities = try RuntimeCapacities(protocolMaximumObjects: 1)
        let clock = PresenceTestClock(nowMS: 76)
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(
            definition: try presenceBuilder(capacities: capacities).finish(), transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        defer { await runtime.stop() }
        try await runtime.start()
        let peer = Self.presencePeer
        let object = try presenceObject(peer)
        try #require(await runtime.advertise(objectID: peer, object: object, leaseMS: 1_000) == .accepted)
        try await waitForPresence("initial managed Advertise") { await transport.publications().count == 1 }

        let before = await runtime.conformanceObservation().state
        try await clock.tick(at: 200)
        // The next phase is 350 ms; a repeat keeps it unchanged.
        clock.advance(to: 230)
        #expect(await runtime.advertise(objectID: peer, object: object, leaseMS: 1_000) == .accepted)
        #expect(await runtime.advertise(objectID: peer, object: object, leaseMS: 1_001) == .rejected(.protocol(.duplicate)))
        let changed = try presenceObject(peer, name: "changed")
        #expect(await runtime.advertise(objectID: peer, object: changed, leaseMS: 1_000) == .rejected(.protocol(.duplicate)))
        let unleased = try RuntimeWirePayload.advertiseEnvelope(object: object, profile: .axoloty1CBOR)
        #expect(await runtime.publish(.advertise(unleased)) == .rejected(.protocol(.duplicate)))
        let other = try presenceObject(Self.secondPresencePeer)
        let unmanagedLease = try RuntimeWirePayload.advertiseEnvelope(
            object: other, leaseMS: 1_000, ownerEpoch: 1, profile: .axoloty1CBOR
        )
        #expect(await runtime.publish(.advertise(unmanagedLease)) == .rejected(.malformedPayload))
        #expect(await runtime.advertise(objectID: Self.secondPresencePeer, object: other, leaseMS: 1_000)
                == .rejected(.capacityExceeded))

        let after = await runtime.conformanceObservation()
        #expect(after.state == before)
        #expect(after.actions.isEmpty)
        #expect(await transport.sentCount() == 1)
        try await clock.tick(at: 297)
        #expect(await transport.sentCount() == 1)
        try await clock.tick(at: 377)
        try await waitForPresence("refresh at the original phase") { await transport.publications().count == 2 }
        let sent = await advertisePublications(transport)
        #expect(sent.first == sent.last)
    }

    @Test("inbound leases use the runtime clock across UInt32 wrap and preserve the frame event timestamp")
    func hostPresenceExpiresFromRuntimeClockAcrossUInt32Wrap() async throws {
        let start = UInt64(UInt32.max) - 499
        let clock = PresenceTestClock(nowMS: start)
        var builder = try presenceBuilder()
        let announcements = try builder.events(matching: .family(.advertise))
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock))
        defer { await runtime.stop() }
        try await runtime.start()

        let frame = try presenceAdvertiseFrame(Self.presencePeer, nowMS: 7)
        await transport.deliver(frame)
        var events = announcements.makeAsyncIterator()
        let announcement = try await nextValue(&events, timeout: .seconds(5))
        #expect(announcement.context.receiptTimeMS == 7)
        #expect(announcement.context.provenance == .transport)
        #expect(await runtime.diagnosticsSnapshot().activeObjects == 1)

        try await clock.tick(at: start + 950)
        #expect(await runtime.diagnosticsSnapshot().activeObjects == 1)
        try await clock.tick(at: start + 1_000)
        let snapshot = await runtime.diagnosticsSnapshot()
        #expect(snapshot.activeObjects == 0)
        #expect(snapshot.lastPresence?.evidence == .peerAdvertisement)
        #expect(snapshot.presenceGeneration == (snapshot.lastPresence?.generation ?? 0) &+ 1)
        var expiries = await runtime.presenceExpiries().makeAsyncIterator()
        let expiry = try await nextValue(&expiries, timeout: .seconds(5))
        #expect(expiry == RuntimePresenceExpiry(
            sourceID: Self.presencePeer, objectID: Self.presencePeer, atMS: UInt32(truncatingIfNeeded: start + 1_000)
        ))
        #expect(await transport.sentCount() == 0)
    }

    @Test("expiry stream overflow drops the newer report and frees every slot")
    func hostPresenceOverflowStillFreesSlots() async throws {
        let capacities = try RuntimeCapacities(stream: 1, protocolMaximumObjects: 2)
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(
            definition: try presenceBuilder(capacities: capacities).finish(), transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        defer { await runtime.stop() }
        try await runtime.start()
        let peer = try presenceAdvertiseFrame(Self.presencePeer)
        let second = try presenceAdvertiseFrame(Self.secondPresencePeer)
        let third = try presenceAdvertiseFrame(Self.thirdPresencePeer)
        #expect(await runtime.receive(peer) == .accepted)
        #expect(await runtime.receive(second) == .accepted)
        #expect(await runtime.receive(third) == .rejected(.capacityExceeded))

        try await clock.tick(at: 1_000)
        let snapshot = await runtime.diagnosticsSnapshot()
        #expect(snapshot.activeObjects == 0)
        #expect(snapshot.presenceExpiriesDropped == 1)
        #expect(await runtime.receive(third) == .accepted)
        #expect(await runtime.receive(second) == .accepted)
        let expiries = await runtime.presenceExpiries()
        await runtime.stop()
        try await withTimeout("stopped presence stream to finish") {
            var iterator = expiries.makeAsyncIterator()
            #expect(await iterator.next()?.objectID == Self.presencePeer)
            #expect(await iterator.next() == nil)
        }
    }

    @Test("silent renewal and expiry leave presence uncertain")
    func hostRenewalLeavesPresenceUncertain() async throws {
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(
            definition: try presenceBuilder().finish(), transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        defer { await runtime.stop() }
        try await runtime.start()
        let frame = try presenceAdvertiseFrame(Self.presencePeer)
        #expect(await runtime.receive(frame) == .accepted)
        await runtime.reconnect()
        let reset = await runtime.diagnosticsSnapshot()
        #expect(reset.presenceUncertain)

        try await clock.tick(at: 500)
        #expect(await runtime.receive(frame) == .accepted)
        let renewed = await runtime.diagnosticsSnapshot()
        #expect(renewed.presenceUncertain)
        #expect(renewed.lastPresence == reset.lastPresence)
        #expect(renewed.presenceChanges == reset.presenceChanges)
        #expect(renewed.diagnosticsEmitted == reset.diagnosticsEmitted)

        try await clock.tick(at: 1_450)
        #expect(await runtime.diagnosticsSnapshot().activeObjects == 1)
        try await clock.tick(at: 1_500)
        let expired = await runtime.diagnosticsSnapshot()
        #expect(expired.activeObjects == 0)
        #expect(expired.presenceUncertain)
        #expect(expired.lastPresence == reset.lastPresence)
        #expect(expired.diagnosticsEmitted == reset.diagnosticsEmitted)
    }

    @Test("delivered Advertise and Deadvertise each restore presence evidence")
    func hostDeliveredAnnounceAndDeadvertiseClearPresenceUncertain() async throws {
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(
            definition: try presenceBuilder().finish(), transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        defer { await runtime.stop() }
        try await runtime.start()
        await runtime.reconnect()
        #expect(await runtime.diagnosticsSnapshot().presenceUncertain)
        let frame = try presenceAdvertiseFrame(Self.presencePeer)
        #expect(await runtime.receive(frame) == .accepted)
        let advertised = await runtime.diagnosticsSnapshot()
        #expect(!advertised.presenceUncertain)
        #expect(advertised.lastPresence?.evidence == .peerAdvertisement)
        #expect(advertised.lastPresence?.objectID == Self.presencePeer)

        await runtime.reconnect()
        #expect(await runtime.diagnosticsSnapshot().presenceUncertain)
        let payload = try presenceDeadvertise(Self.presencePeer)
        let route = try presenceRoute(.deadvertise, sourceID: Self.presencePeer)
        #expect(await runtime.receive(.profile(route: route, payload: payload, nowMS: 4)) == .accepted)
        let deadvertised = await runtime.diagnosticsSnapshot()
        #expect(!deadvertised.presenceUncertain)
        #expect(deadvertised.lastPresence?.evidence == .peerDeadvertisement)
        #expect(deadvertised.lastPresence?.sourceID == Self.presencePeer)
        #expect(deadvertised.activeObjects == 0)
    }
}

extension AxolotyRuntimeTests {
    @Test("refresh uses the same wire bytes without a second local event, receipt, or presence observation")
    func hostAdvertiseRefreshesIdenticalBytesWithoutLocalRedelivery() async throws {
        // FNV-1a of the zero source and peer object gives phase 76 ms modulo 222 ms.
        let clock = PresenceTestClock(nowMS: 76)
        var builder = try presenceBuilder()
        let announcements = try builder.events(matching: .family(.advertise), buffering: .failAfterDrop(capacity: 1))
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock))
        defer { await runtime.close() }
        try await runtime.start()

        let object = try presenceObject(Self.presencePeer)
        try #require(await runtime.advertise(objectID: Self.presencePeer, object: object, leaseMS: 1_000) == .accepted)
        try await waitForPresence("initial leased Advertise") { await transport.publications().count == 1 }
        let first = try #require(await transport.publications().first)
        let envelope = try first.payload.withUnsafeBufferPointer { buffer throws(WireDecodeError) in
            let reader = WireCodec(profile: .axoloty1CBOR).reader(bytes: buffer.baseAddress!, length: buffer.count)
            let value = try AdvertiseWireData(from: reader)
            #expect(value.leaseMS == 1_000)
            #expect(value.ownerEpoch.map { (1...Int(Int32.max)).contains($0) } == true)
            return value.object.ownedBytes()
        }
        #expect(envelope == object)
        #expect(first.route.hasSuffix("/00000000-0000-0000-0000-000000000000"))
        let before = await runtime.diagnosticsSnapshot()

        try await clock.tick(at: 297)
        #expect(await transport.sentCount() == 1)
        try await clock.tick(at: 377)
        try await waitForPresence("refresh at the next phase") { await transport.publications().count == 2 }
        #expect(await transport.publications() == [first, first])
        let after = await runtime.diagnosticsSnapshot()
        #expect(after.lifecycleState == .running)
        #expect(after.lastPresence == before.lastPresence)
        #expect(after.presenceChanges == before.presenceChanges)
        #expect(after.diagnosticsEmitted == before.diagnosticsEmitted)

        let receipts = await runtime.events()
        await runtime.close()
        try await withTimeout("finished announcement and receipt streams") {
            var announcementIterator = announcements.makeAsyncIterator()
            let announcement = await announcementIterator.next()
            #expect(announcement?.context.provenance == .local)
            #expect(announcement?.value == first.payload)
            #expect(await announcementIterator.next() == nil)
            var receiptIterator = receipts.makeAsyncIterator()
            #expect(await receiptIterator.next() == .transition(.accepted))
            #expect(await receiptIterator.next() == nil)
        }
    }

    @Test("a blocked refresh holds one batch and another due object retries after saturation")
    func hostRefreshSaturationDoesNotDuplicatePendingBatches() async throws {
        let capacities = try RuntimeCapacities(dispatch: 2)
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(
            definition: try presenceBuilder(capacities: capacities).finish(), transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        defer {
            await transport.releasePublication()
            await runtime.stop()
        }
        try await runtime.start()
        try #require(await runtime.advertise(
            objectID: Self.presencePeer, object: try presenceObject(Self.presencePeer), leaseMS: 1_000
        ) == .accepted)
        try #require(await runtime.advertise(
            objectID: Self.secondPresencePeer, object: try presenceObject(Self.secondPresencePeer), leaseMS: 45_000
        ) == .accepted)
        try await waitForPresence("two initial Advertise publications") { await transport.publications().count == 2 }
        let first = try #require(await transport.publications().first)
        let second = try #require(await transport.publications().last)
        _ = await runtime.conformanceObservation()

        await transport.blockNextPublication()
        try await clock.tick(at: 200)
        try await waitForPresence("first refresh in flight") { await transport.waitingForPublication() }
        try await clock.tick(at: 450)
        let inFlight = await runtime.conformanceObservation()
        // The 45 s object is not due yet; only the in-flight refresh was admitted.
        try #require(inFlight.actions.count == 1)
        #expect(await transport.sentCount() == 3)

        let withdrawal = try presenceDeadvertise(Self.presencePeer)
        try #require(await runtime.publish(.deadvertise(withdrawal)) == .accepted)
        let before = await runtime.conformanceObservation().state
        let other = try presenceObject(Self.thirdPresencePeer)
        #expect(await runtime.advertise(objectID: Self.thirdPresencePeer, object: other, leaseMS: 1_000)
                == .rejected(.capacityExceeded))
        // With the refresh and Deadvertise occupying both slots, the 4,539 ms
        // phase for the 45 s lease passes without admitting a refresh.
        try await clock.tick(at: 4_575)
        let saturated = await runtime.conformanceObservation()
        #expect(saturated.state == before)
        #expect(saturated.actions.isEmpty)
        #expect(await runtime.diagnosticsSnapshot().dispatchSaturation == 0)

        await transport.releasePublication()
        try await waitForPresence("refresh and subsequent withdrawal to finish") { await transport.publications().count >= 4 }
        try await clock.tick(at: 4_600)
        try await waitForPresence("blocked object to refresh after capacity frees") {
            await transport.publications().count >= 5
        }
        #expect(await advertisePublications(transport) == [first, second, first, second])
    }

    @Test("hard and soft recovery rebase leases and phase and discard managed effects from replay", arguments: [true, false])
    func hostPresenceSuspendsAndRebasesOnHardAndSoftRecovery(hard: Bool) async throws {
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(
            definition: try presenceBuilder().finish(), transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        defer { await runtime.stop() }
        try await runtime.start()
        try #require(await runtime.advertise(
            objectID: Self.presencePeer, object: try presenceObject(Self.presencePeer), leaseMS: 1_000
        ) == .accepted)
        try await waitForPresence("initial managed Advertise") { await transport.publications().count == 1 }
        let initial = try #require(await transport.publications().first)
        let peer = try presenceAdvertiseFrame(Self.secondPresencePeer)
        #expect(await runtime.receive(peer) == .accepted)

        await transport.failNextPublication()
        clock.advance(to: 200)
        try await waitForPresence("failed refresh to suspend presence") { await runtime.state() == .reconnecting }
        #expect(await transport.sentCount() == 2)
        #expect(await transport.publications() == [initial])
        clock.advance(to: 1_200)
        #expect(clock.sleepingUntil == nil)
        #expect(await runtime.diagnosticsSnapshot().activeObjects == 2)

        let marker = try RuntimeWirePayload.emptyObject(profile: .axoloty1CBOR)
        #expect(await runtime.publish(.channel(identifier: "recovery-marker", payload: marker)) == .accepted)
        if hard {
            await runtime.reconnect()
        } else {
            await transport.recover()
        }
        try await waitForPresence("recovered runtime to admit offline work") {
            await transport.publications().contains { routeEventType($0.route) == "CHN" }
        }
        #expect(await runtime.state() == .running)
        #expect(await advertisePublications(transport) == [initial])
        #expect(await transport.startCount() == (hard ? 2 : 1))

        // The next phase after 1,200 ms is 1,408 ms. The 50 ms timer
        // sees it on the first tick after recovery.
        try await clock.tick(at: 1_407)
        #expect(await advertisePublications(transport) == [initial])
        try await clock.tick(at: 1_450)
        try await waitForPresence("managed refresh in the new epoch") { await advertisePublications(transport).count == 2 }
        #expect(await advertisePublications(transport) == [initial, initial])

        try await clock.tick(at: 2_150)
        #expect(await runtime.diagnosticsSnapshot().activeObjects == 2)
        try await clock.tick(at: 2_200)
        #expect(await runtime.diagnosticsSnapshot().activeObjects == 1)
        var expiries = await runtime.presenceExpiries().makeAsyncIterator()
        let expired = try await nextValue(&expiries, timeout: .seconds(5))
        #expect(expired.sourceID == Self.secondPresencePeer)
        #expect(expired.atMS == 2_200)
    }

    @Test("reconnecting disarms the timer and rejects managed declarations and withdrawals")
    func hostPresenceNeverRefreshesWhileReconnecting() async throws {
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(
            definition: try presenceBuilder().finish(), transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        defer {
            await transport.releaseStart()
            await runtime.stop()
        }
        try await runtime.start()
        let object = try presenceObject(Self.presencePeer)
        try #require(await runtime.advertise(objectID: Self.presencePeer, object: object, leaseMS: 1_000) == .accepted)
        try await waitForPresence("initial managed Advertise") { await transport.publications().count == 1 }
        try await waitForPresence("initial presence timer sleep") { clock.sleepingUntil == 50 }

        await transport.blockNextStart()
        let reconnect = Task { await runtime.reconnect() }
        try await waitForPresence("reconnect waiting in transport start") { await transport.waitingForStart() }
        let sleepRequests = clock.sleepRequests
        clock.advance(to: 20_000)
        #expect(clock.sleepingUntil == nil)
        #expect(clock.sleepRequests == sleepRequests)
        #expect(await runtime.advertise(objectID: Self.presencePeer, object: object, leaseMS: 1_000)
                == .rejected(.notRunning(.reconnecting)))
        let withdrawal = try presenceDeadvertise(Self.presencePeer)
        #expect(await runtime.publish(.deadvertise(withdrawal)) == .rejected(.notRunning(.reconnecting)))
        #expect(await transport.sentCount() == 1)

        await transport.releaseStart()
        await reconnect.value
        #expect(await runtime.state() == .running)
        #expect(await transport.sentCount() == 1)
        try await clock.tick(at: 20_250)
        try await waitForPresence("refresh after the transport is ready") { await transport.publications().count == 2 }
        #expect(await advertisePublications(transport).count == 2)
    }

    @Test("cancelling a reconnect keeps the timer suspended until a successful retry")
    func hostCancelledReconnectDoesNotArmPresenceTimer() async throws {
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(
            definition: try presenceBuilder().finish(), transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        defer {
            await transport.releaseStart()
            await runtime.stop()
        }
        try await runtime.start()
        try #require(await runtime.advertise(
            objectID: Self.presencePeer, object: try presenceObject(Self.presencePeer), leaseMS: 1_000
        ) == .accepted)
        try await waitForPresence("initial managed Advertise") { await transport.publications().count == 1 }
        try await waitForPresence("initial timer sleep") { clock.sleepingUntil == 50 }

        await transport.blockNextStart()
        let reconnect = Task { await runtime.reconnect() }
        try await waitForPresence("reconnect reaching transport start") { await transport.waitingForStart() }
        let sleepRequests = clock.sleepRequests
        reconnect.cancel()
        clock.advance(to: 5_000)
        await transport.releaseStart()
        await reconnect.value
        #expect(await runtime.state() == .reconnecting)
        #expect(clock.sleepingUntil == nil)
        #expect(clock.sleepRequests == sleepRequests)
        #expect(await transport.sentCount() == 1)

        clock.advance(to: 10_000)
        await runtime.reconnect()
        #expect(await runtime.state() == .running)
        try await waitForPresence("new timer after successful retry") { clock.sleepingUntil == 10_050 }
        #expect(clock.sleepRequests == sleepRequests + 1)
        #expect(await transport.sentCount() == 1)
    }

    @Test("a superseded reconnect cannot rebase the replacement timer")
    func hostSupersededReconnectKeepsNewestPresenceTimer() async throws {
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(
            definition: try presenceBuilder().finish(), transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        defer {
            await transport.releaseStart()
            await runtime.stop()
        }
        try await runtime.start()
        await transport.blockNextStart()
        let stale = Task { await runtime.reconnect() }
        try await waitForPresence("first reconnect blocked") { await transport.waitingForStart() }

        clock.advance(to: 1_500)
        await runtime.reconnect()
        try await waitForPresence("current reconnect to arm its timer") { clock.sleepingUntil == 1_550 }
        let sleepRequests = clock.sleepRequests
        clock.advance(to: 1_525)
        await transport.releaseStart()
        await stale.value
        #expect(await runtime.state() == .running)
        #expect(clock.sleepingUntil == 1_550)
        #expect(clock.sleepRequests == sleepRequests)
        try await clock.tick(at: 1_550)
        #expect(clock.sleepingUntil == 1_600)
    }

    @Test("explicit Deadvertise retires all named leases and skips their queued publications")
    func hostDeadvertiseRetiresTheManagedObject() async throws {
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(
            definition: try presenceBuilder().finish(), transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        defer {
            await transport.releasePublication()
            await runtime.stop()
        }
        try await runtime.start()

        await transport.blockNextPublication()
        let marker = try RuntimeWirePayload.emptyObject(profile: .axoloty1CBOR)
        #expect(await runtime.publish(.channel(identifier: "before-withdrawal", payload: marker)) == .accepted)
        try await waitForPresence("outbound pump blocked before managed declarations") {
            await transport.waitingForPublication()
        }
        try #require(await runtime.advertise(
            objectID: Self.presencePeer, object: try presenceObject(Self.presencePeer), leaseMS: 1_000
        ) == .accepted)
        try #require(await runtime.advertise(
            objectID: Self.secondPresencePeer, object: try presenceObject(Self.secondPresencePeer), leaseMS: 1_000
        ) == .accepted)
        let withdrawal = try presenceMultiObjectDeadvertise(Self.presencePeer, Self.secondPresencePeer)
        try #require(await runtime.publish(.deadvertise(withdrawal)) == .accepted)
        #expect(await runtime.diagnosticsSnapshot().activeObjects == 0)

        // A new declaration can reuse the same identity while the old
        // publication is queued. Only the new declaration can reach the wire.
        try #require(await runtime.advertise(
            objectID: Self.presencePeer, object: try presenceObject(Self.presencePeer, name: "redeclared"), leaseMS: 1_000
        ) == .accepted)
        await transport.releasePublication()
        try await waitForPresence("marker, withdrawal, and new declaration") { await transport.publications().count >= 3 }
        let sent = await transport.publications()
        #expect(sent.map { routeEventType($0.route) } == ["CHN", "DAD", "ADV"])
        #expect(sent.dropFirst().first?.payload == withdrawal)

        try await clock.tick(at: 200)
        try await waitForPresence("new declaration to refresh") { await transport.publications().count >= 4 }
        #expect(await advertisePublications(transport).count == 2)
        await runtime.stop()
        let withdrawn = await transport.publications().filter { isDeadvertiseRoute($0.route) }.map(\.payload)
        let finalWithdrawal = try presenceDeadvertise(Self.presencePeer)
        #expect(withdrawn == [withdrawal, finalWithdrawal])
    }

    @Test("stop joins an in-flight refresh, skips queued refreshes, and sends withdrawals before deactivation")
    func hostStopWaitsForInFlightRefreshBeforeDeadvertise() async throws {
        let capacities = try RuntimeCapacities(dispatch: 3)
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(
            definition: try presenceBuilder(capacities: capacities).finish(), transport: transport, presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        defer {
            await transport.releasePublication()
            await runtime.close()
        }
        try await runtime.start()
        for id in [Self.presencePeer, Self.secondPresencePeer] {
            let object = try presenceObject(id)
            try #require(await runtime.advertise(objectID: id, object: object, leaseMS: 1_000) == .accepted)
        }
        try await waitForPresence("initial advertisements") { await transport.publications().count == 2 }
        let initial = await transport.publications()
        _ = await runtime.conformanceObservation()

        await transport.blockNextPublication()
        try await clock.tick(at: 200)
        try await waitForPresence("first refresh in flight") { await transport.waitingForPublication() }
        #expect(await runtime.conformanceObservation().actions.count == 2)
        let stopping = Task { await runtime.stop() }
        try await waitForPresence("stop to disarm the timer") {
            let state = await runtime.lifecycleState()
            return state == .stopping && clock.sleepingUntil == nil
        }
        let closing = Task { await runtime.close() }
        #expect(await transport.deactivationPublicationCounts.isEmpty)
        #expect(await transport.publications() == initial)

        await transport.releasePublication()
        await stopping.value
        await closing.value
        let messages = await transport.publications()
        #expect(messages.map { routeEventType($0.route) } == ["ADV", "ADV", "ADV", "DAD", "DAD"])
        // The 69 ms phase refreshes before the 76 ms phase, so stop delivers
        // the later declaration's refresh and skips the earlier one.
        #expect(messages.dropFirst(2).first == initial.last)
        let firstWithdrawal = try presenceDeadvertise(Self.presencePeer)
        let secondWithdrawal = try presenceDeadvertise(Self.secondPresencePeer)
        #expect(messages.suffix(2).map(\.payload) == [firstWithdrawal, secondWithdrawal])
        #expect(await transport.deactivationPublicationCounts == [5])
        #expect(await runtime.state() == .closed)
    }

    @Test("presence configuration validates its lease bounds")
    func presenceConfigurationValidatesLeaseBounds() throws {
        #expect(try RuntimePresenceConfiguration().leaseMS == 45_000)
        #expect(try RuntimePresenceConfiguration(leaseMS: 1_000).leaseMS == 1_000)
        #expect(try RuntimePresenceConfiguration(leaseMS: 3_600_000).leaseMS == 3_600_000)
        for leaseMS: UInt32 in [0, 999, 3_600_001] {
            do {
                _ = try RuntimePresenceConfiguration(leaseMS: leaseMS)
                Issue.record("expected lease \(leaseMS) to be rejected")
            } catch let error {
                guard case let .invalidArgument(argument, _) = error else {
                    Issue.record("unexpected error \(error)")
                    continue
                }
                #expect(argument == "presence.leaseMS")
            }
        }
    }

    @Test("the owner epoch is scoped to one runtime instance")
    func hostPresenceOwnerEpochIsPerRuntimeInstance() async throws {
        let identity = try RuntimeIdentity(id: .zero, name: "epoch-owner")
        let definition = try RuntimeBuilder(
            identity: identity,
            namespace: "presence",
            presence: try RuntimePresenceConfiguration()
        ).finish()
        var observed: [Int] = []
        for ownerEpoch in [41, 42] {
            let clock = PresenceTestClock()
            let transport = TestTransport(wireProfile: .axoloty1CBOR)
            let runtime = AxolotyRuntime(
                definition: definition,
                transport: transport,
                presence: RuntimePresenceEnvironment(clock: clock.clock, ownerEpoch: ownerEpoch)
            )
            try await runtime.start()
            let advertisement = try #require(await advertisePublications(transport).first)
            let value = try advertisement.payload.withUnsafeBufferPointer { buffer throws(WireDecodeError) in
                let reader = WireCodec(profile: .axoloty1CBOR).reader(bytes: buffer.baseAddress!, length: buffer.count)
                return try AdvertiseWireData(from: reader)
            }
            observed.append(try #require(value.ownerEpoch))
            await runtime.stop()
        }
        #expect(observed == [41, 42])
    }

    @Test("refresh phases spread objects instead of bursting in one tick")
    func hostPresenceSpreadsRefreshPhaseAcrossObjects() async throws {
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(
            definition: try presenceBuilder().finish(),
            transport: transport,
            presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        defer { await runtime.stop() }
        try await runtime.start()
        for id in [Self.presencePeer, Self.secondPresencePeer] {
            try #require(await runtime.advertise(objectID: id, object: try presenceObject(id), leaseMS: 10_000) == .accepted)
        }
        try await waitForPresence("initial advertisements") { await advertisePublications(transport).count == 2 }

        // The second object's phase is 177 ms and the first object's is 1,658 ms.
        try await clock.tick(at: 200)
        try await waitForPresence("second object refresh") { await advertisePublications(transport).count == 3 }
        let firstRefresh = await advertisePublications(transport)
        #expect(try presenceAdvertisedObjectID(firstRefresh[2].payload) == Self.secondPresencePeer)
        try await clock.tick(at: 1_700)
        try await waitForPresence("first object refresh") { await advertisePublications(transport).count == 4 }
        let secondRefresh = await advertisePublications(transport)
        #expect(try presenceAdvertisedObjectID(secondRefresh[3].payload) == Self.presencePeer)
    }

    @Test("stop aborts withdrawal after the first dead-transport failure")
    func hostStopOnDeadTransportAbortsWithdrawalAfterFirstFailure() async throws {
        let clock = PresenceTestClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let runtime = AxolotyRuntime(
            definition: try presenceBuilder().finish(),
            transport: transport,
            presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        try await runtime.start()
        for id in [Self.presencePeer, Self.secondPresencePeer] {
            try #require(await runtime.advertise(objectID: id, object: try presenceObject(id), leaseMS: 1_000) == .accepted)
        }
        try await waitForPresence("initial advertisements") { await transport.publications().count == 2 }
        await transport.failNextPublication()
        await runtime.stop()
        #expect(await runtime.state() == .stopped)
        // Initial two Advertise publications plus exactly one attempted withdrawal.
        #expect(await transport.sentCount() == 3)
    }
}

private func presenceAdvertisedObjectID(_ payload: [UInt8]) throws(WireDecodeError) -> UUID16? {
    try payload.withUnsafeBufferPointer { buffer throws(WireDecodeError) -> UUID16? in
        let reader = WireCodec(profile: .axoloty1CBOR).reader(bytes: buffer.baseAddress!, length: buffer.count)
        let value = try AdvertiseWireData(from: reader)
        let object = value.object.ownedBytes()
        return object.withUnsafeBufferPointer { objectBuffer in
            WireCodec(profile: .axoloty1CBOR)
                .reader(bytes: objectBuffer.baseAddress!, length: objectBuffer.count)
                .readUUID("objectId")
        }
    }
}

private func presenceMultiObjectDeadvertise(_ firstID: UUID16, _ secondID: UUID16) throws(AxolotyError) -> [UInt8] {
    do {
        var output = [UInt8](repeating: 0, count: 64)
        let length = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) -> Int in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(buffer: buffer.baseAddress!, capacity: buffer.count)
            try writer.beginArray()
            try writer.writeUUIDValue(firstID)
            try writer.writeUUIDValue(secondID)
            try writer.endArray()
            return writer.position
        }
        let data = try OwnedDeadvertiseWireData(profile: .axoloty1CBOR, objectIds: Array(output.prefix(length)))
        return try OwnedWireEvent.deadvertise(data).encodedBytes(capacity: 128)
    } catch {
        throw .caught(error)
    }
}
