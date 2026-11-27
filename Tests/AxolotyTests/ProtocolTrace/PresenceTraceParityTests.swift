// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyProtocol
import AxolotyStaticRuntime
import AxolotyTestSupport
import AxolotyWire
import Synchronization
import Testing
@testable import Axoloty

/// Replays one soft-state presence trace through the host runtime and the
/// static runtime, then compares state, delivered actions, expiry reports, and
/// structured rejections after every step.
///
/// The host drives refresh and expiry from its bounded presence timer on an
/// injected clock. The static caller supplies the same times directly. Both
/// legs use the same `axoloty/1` CBOR frames and the same shared processor
/// presence policy.
@Suite("Host and static presence parity")
struct PresenceTraceParityTests {
    private static let peer = UUID16(parsing: "00000000-0000-4000-8000-000000000701")!

    // MARK: - Comparable observations

    private struct ParityState: Equatable {
        let activeObjectIDs: [UUID16]
        let associationSourceIDs: [UUID16]
        let generation: UInt32
    }

    private struct ParityDelivery: Equatable {
        let capability: ProtocolCapability
        let sourceID: UUID16
        let payload: [UInt8]
    }

    private struct ParityStep: Equatable {
        let accepted: Bool
        let rejection: ProtocolError.Code?
        let state: ParityState
        let deliveries: [ParityDelivery]
    }

    // MARK: - Trace

    @Test("host and static replay refresh, expiry, late refresh, and Deadvertise identically")
    func presenceTraceParity() async throws {
        let clock = ParityClock()
        let transport = TestTransport(wireProfile: .axoloty1CBOR)
        let hostDefinition = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "presence",
            capacities: try RuntimeCapacities(protocolMaximumObjects: 4),
            presence: try RuntimePresenceConfiguration()
        ).finish()
        let runtime = AxolotyRuntime(
            definition: hostDefinition,
            transport: transport,
            presence: RuntimePresenceEnvironment(clock: clock.clock)
        )
        defer { await runtime.stop() }
        try await runtime.start()
        var expiries = await runtime.presenceExpiries().makeAsyncIterator()

        let staticDefinition = try StaticRuntimeDefinition<512>(
            registryID: ObjectID(uuid: .zero),
            wireCodec: WireCodec(profile: .axoloty1CBOR),
            presencePolicy: .enabled
        )
        var staticRuntime = StaticRuntime<4, 512>(
            definition: staticDefinition,
            routeClassifier: ExactProtocolRouteClassifier(externalRoute: "external/parity-none")
        )

        let peer = Self.peer
        let leased = try advertisePayload(peer, leaseMS: 1_000, ownerEpoch: 1)
        let renewed = leased
        let deadvertise = try RuntimeWirePayload.deadvertise(uuid: peer, profile: .axoloty1CBOR)
        let malformedLease = try malformedLeasePayload(peer)
        let nonMapObject = try advertiseEnvelope(objectBytes: [0x07], leaseMS: 1_000, ownerEpoch: 1)
        let objectWithoutID = try advertiseEnvelope(
            objectBytes: try objectPayload(fields: [("coreType", "IoSource")]),
            leaseMS: 1_000,
            ownerEpoch: 1
        )
        let nonUUIDObjectID = try advertiseEnvelope(
            objectBytes: try objectPayload(fields: [("objectId", "not-a-uuid")]),
            leaseMS: 1_000,
            ownerEpoch: 1
        )
        let wrongKindAssociate = try associateEnvelope(route: [0x18, 0x2A])
        let emptyAssociate = try associateEnvelope(route: [0x60])

        // 1. Announce, 2. silent renewal, 3. expiry, 4. late refresh,
        // 5. graceful Deadvertise, 6. resurrection, 7. malformed rejection.
        let announce = try await step(
            host: runtime,
            hostClock: clock,
            staticRuntime: &staticRuntime,
            capability: .advertise,
            sourceID: peer,
            payload: leased,
            nowMS: 100
        )
        let refresh = try await step(
            host: runtime,
            hostClock: clock,
            staticRuntime: &staticRuntime,
            capability: .advertise,
            sourceID: peer,
            payload: renewed,
            nowMS: 500
        )
        let expired = try await expiryStep(
            host: runtime,
            hostClock: clock,
            staticRuntime: &staticRuntime,
            hostExpiries: &expiries,
            nowMS: 1_500
        )
        let late = try await step(
            host: runtime,
            hostClock: clock,
            staticRuntime: &staticRuntime,
            capability: .advertise,
            sourceID: peer,
            payload: leased,
            nowMS: 1_600
        )
        let withdrew = try await step(
            host: runtime,
            hostClock: clock,
            staticRuntime: &staticRuntime,
            capability: .deadvertise,
            sourceID: peer,
            payload: deadvertise,
            nowMS: 1_700
        )
        let resurrected = try await step(
            host: runtime,
            hostClock: clock,
            staticRuntime: &staticRuntime,
            capability: .advertise,
            sourceID: peer,
            payload: leased,
            nowMS: 1_800
        )
        let rejected = try await step(
            host: runtime,
            hostClock: clock,
            staticRuntime: &staticRuntime,
            capability: .advertise,
            sourceID: peer,
            payload: malformedLease,
            nowMS: 1_900
        )

        // 8. Non-map object, 9. object without objectId, 10. non-UUID objectId,
        // 11. wrong-kind Associate route, 12. empty Associate route. Each must
        // reject identically on both legs without mutating state.
        let wrongObject = try await step(
            host: runtime,
            hostClock: clock,
            staticRuntime: &staticRuntime,
            capability: .advertise,
            sourceID: peer,
            payload: nonMapObject,
            nowMS: 2_000
        )
        let missingID = try await step(
            host: runtime,
            hostClock: clock,
            staticRuntime: &staticRuntime,
            capability: .advertise,
            sourceID: peer,
            payload: objectWithoutID,
            nowMS: 2_100
        )
        let nonUUIDID = try await step(
            host: runtime,
            hostClock: clock,
            staticRuntime: &staticRuntime,
            capability: .advertise,
            sourceID: peer,
            payload: nonUUIDObjectID,
            nowMS: 2_200
        )
        let wrongKindRoute = try await step(
            host: runtime,
            hostClock: clock,
            staticRuntime: &staticRuntime,
            capability: .associate,
            sourceID: peer,
            payload: wrongKindAssociate,
            nowMS: 2_300
        )
        let emptyRoute = try await step(
            host: runtime,
            hostClock: clock,
            staticRuntime: &staticRuntime,
            capability: .associate,
            sourceID: peer,
            payload: emptyAssociate,
            nowMS: 2_400
        )

        #expect(announce.accepted && announce.deliveries.count == 1)
        #expect(refresh.accepted && refresh.deliveries.isEmpty)
        #expect(refresh.state == announce.state)
        #expect(expired.reports == 1)
        #expect(expired.activeObjectIDs.isEmpty)
        #expect(late.accepted && late.deliveries.count == 1)
        #expect(withdrew.accepted && withdrew.deliveries.count == 1)
        #expect(withdrew.state.activeObjectIDs.isEmpty)
        #expect(resurrected.accepted && resurrected.deliveries.count == 1)
        #expect(!rejected.accepted)
        #expect(rejected.rejection == .malformedPayload)
        #expect(rejected.state == resurrected.state)
        #expect(rejected.deliveries.isEmpty)

        for step in [wrongObject, missingID, nonUUIDID, wrongKindRoute, emptyRoute] {
            #expect(!step.accepted)
            #expect(step.rejection == ProtocolError.Code.malformedPayload)
            #expect(step.state == resurrected.state)
            #expect(step.deliveries.isEmpty)
        }
    }

    // MARK: - Step execution

    private struct ExpiryStep {
        let reports: Int
        let activeObjectIDs: [UUID16]
    }

    private func step(
        host: AxolotyRuntime,
        hostClock: ParityClock,
        staticRuntime: inout StaticRuntime<4, 512>,
        capability: ProtocolCapability,
        sourceID: UUID16,
        payload: [UInt8],
        nowMS: UInt64
    ) async throws -> ParityStep {
        try await hostClock.tick(at: nowMS)
        let hostStep = try await hostStep(
            host: host,
            capability: capability,
            sourceID: sourceID,
            payload: payload,
            nowMS: UInt32(truncatingIfNeeded: nowMS)
        )
        let staticStep = try staticStep(
            &staticRuntime,
            capability: capability,
            sourceID: sourceID,
            payload: payload,
            nowMS: UInt32(truncatingIfNeeded: nowMS)
        )
        #expect(hostStep == staticStep)
        return hostStep
    }

    private func expiryStep(
        host: AxolotyRuntime,
        hostClock: ParityClock,
        staticRuntime: inout StaticRuntime<4, 512>,
        hostExpiries: inout AsyncStream<RuntimePresenceExpiry>.AsyncIterator,
        nowMS: UInt64
    ) async throws -> ExpiryStep {
        try await hostClock.tick(at: nowMS)
        let hostExpiry = try await nextValue(&hostExpiries, timeout: .seconds(5))
        let staticExpiry = staticRuntime.expirePresence(nowMS: UInt32(truncatingIfNeeded: nowMS))
        #expect(hostExpiry.sourceID == staticExpiry?.sourceID)
        #expect(hostExpiry.objectID == staticExpiry?.objectID)

        let hostState = await host.conformanceObservation().state
        let staticState = parityState(staticRuntime)
        #expect(hostParityState(hostState) == staticState)
        return ExpiryStep(
            reports: staticExpiry == nil ? 0 : 1,
            activeObjectIDs: staticState.activeObjectIDs
        )
    }

    private func hostStep(
        host: AxolotyRuntime,
        capability: ProtocolCapability,
        sourceID: UUID16,
        payload: [UInt8],
        nowMS: UInt32
    ) async throws -> ParityStep {
        let frame = RuntimeInboundFrame.profile(
            route: try route(capability: capability, sourceID: sourceID),
            payload: payload,
            nowMS: nowMS
        )
        let receipt = await host.receive(frame)
        let observation = await host.conformanceObservation()
        let deliveries = observation.actions.compactMap { action -> ParityDelivery? in
            guard case .deliver(let delivery) = action else {
                Issue.record("host emitted a non-delivery action: \(action)")
                return nil
            }
            return ParityDelivery(
                capability: delivery.routingKey.capability,
                sourceID: delivery.routingKey.sourceID,
                payload: delivery.payload
            )
        }
        return ParityStep(
            accepted: receipt == .accepted,
            rejection: rejectionCode(receipt),
            state: hostParityState(observation.state),
            deliveries: deliveries
        )
    }

    private func staticStep(
        _ runtime: inout StaticRuntime<4, 512>,
        capability: ProtocolCapability,
        sourceID: UUID16,
        payload: [UInt8],
        nowMS: UInt32
    ) throws -> ParityStep {
        let topic = try route(capability: capability, sourceID: sourceID)
        let topicBytes = Array(topic.utf8)
        let outcome = topicBytes.withUnsafeBufferPointer { topicBuffer in
            payload.withUnsafeBufferPointer { payloadBuffer in
                runtime.receive(
                    topic: ByteSlice(bytes: topicBuffer.baseAddress!, length: topicBuffer.count),
                    payload: ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count),
                    nowMS: nowMS
                )
            }
        }
        var deliveries: [ParityDelivery] = []
        runtime.drain { action in
            guard case .deliver(let delivery) = action else {
                Issue.record("static runtime emitted a non-delivery action")
                return
            }
            deliveries.append(ParityDelivery(
                capability: delivery.routingKey.capability,
                sourceID: delivery.routingKey.sourceID,
                payload: delivery.payload.ownedBytes()
            ))
        }
        return ParityStep(
            accepted: outcome == .accepted,
            rejection: {
                guard case .rejected(let code) = outcome else { return nil }
                return code
            }(),
            state: parityState(runtime),
            deliveries: deliveries
        )
    }

    // MARK: - State and rejection mapping

    private func parityState(_ runtime: borrowing StaticRuntime<4, 512>) -> ParityState {
        var projection = ProtocolFixedStateSnapshot<4>()
        runtime.copyState(into: &projection)
        var objects: [UUID16] = []
        var associations: [UUID16] = []
        for index in 0..<projection.activeObjectCount {
            if let value = projection.activeObjectIDs[index] { objects.append(value) }
        }
        for index in 0..<projection.associationCount {
            if let value = projection.associationSourceIDs[index] { associations.append(value) }
        }
        return ParityState(
            activeObjectIDs: sortUUIDs(objects),
            associationSourceIDs: sortUUIDs(associations),
            generation: runtime.state.generation
        )
    }

    private func hostParityState(_ state: RuntimeConformanceState) -> ParityState {
        ParityState(
            activeObjectIDs: sortUUIDs(state.activeObjectIDs),
            associationSourceIDs: sortUUIDs(state.associationSourceIDs),
            generation: state.generation
        )
    }

    private func sortUUIDs(_ values: [UUID16]) -> [UUID16] {
        values.sorted { left, right in
            let leftBytes = withUnsafeBytes(of: left.bytes) { Array($0) }
            let rightBytes = withUnsafeBytes(of: right.bytes) { Array($0) }
            return leftBytes.lexicographicallyPrecedes(rightBytes)
        }
    }

    private func rejectionCode(_ receipt: RuntimeReceipt) -> ProtocolError.Code? {
        guard case .rejected(let rejection) = receipt else { return nil }
        switch rejection {
        case .protocol(let code), .malformedFrame(let code): return code
        case .malformedPayload: return .malformedPayload
        case .capacityExceeded: return .capacityExceeded
        case .invalidOperationName: return .malformedPayload
        case .notRunning, .staleTransport: return nil
        }
    }

    // MARK: - Wire helpers

    private func route(capability: ProtocolCapability, sourceID: UUID16) throws -> String {
        try CoatyRoute.route(
            for: ProtocolRoutingKey(capability: capability, sourceID: sourceID),
            namespace: "presence",
            profile: .axoloty1CBOR
        )
    }

    private func advertisePayload(_ objectID: UUID16, leaseMS: Int, ownerEpoch: Int) throws(ProtocolError) -> [UInt8] {
        let object = try objectPayload(objectID)
        return try RuntimeWirePayload.advertiseEnvelope(
            object: object,
            leaseMS: leaseMS,
            ownerEpoch: ownerEpoch,
            profile: .axoloty1CBOR
        )
    }

    private func malformedLeasePayload(_ objectID: UUID16) throws -> [UInt8] {
        let object = try objectPayload(objectID)
        var output = [UInt8](repeating: 0, count: 512)
        let length = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) -> Int in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: buffer.baseAddress!,
                capacity: buffer.count
            )
            try writer.beginObject()
            try object.withUnsafeBufferPointer { objectBuffer throws(WireEncodeError) in
                try writer.writeRawField(
                    "object",
                    ByteSlice(bytes: objectBuffer.baseAddress!, length: objectBuffer.count)
                )
            }
            try writer.writeComma()
            try writer.writeIntField("leaseMs", 1_000)
            try writer.endObject()
            return writer.position
        }
        return Array(output.prefix(length))
    }

    private func advertiseEnvelope(
        objectBytes: [UInt8],
        leaseMS: Int,
        ownerEpoch: Int
    ) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 512)
        let length = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) -> Int in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: buffer.baseAddress!,
                capacity: buffer.count
            )
            try writer.beginObject()
            try objectBytes.withUnsafeBufferPointer { objectBuffer throws(WireEncodeError) in
                try writer.writeRawField(
                    "object",
                    ByteSlice(bytes: objectBuffer.baseAddress!, length: objectBuffer.count)
                )
            }
            try writer.writeComma()
            try writer.writeIntField("leaseMs", leaseMS)
            try writer.writeComma()
            try writer.writeIntField("ownerEpoch", ownerEpoch)
            try writer.endObject()
            return writer.position
        }
        return Array(output.prefix(length))
    }

    private func associateEnvelope(route: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 256)
        let length = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) -> Int in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: buffer.baseAddress!,
                capacity: buffer.count
            )
            try writer.beginObject()
            try writer.writeUUIDField("ioSourceId", Self.peer)
            try writer.writeComma()
            try writer.writeUUIDField("ioActorId", Self.peer)
            try writer.writeComma()
            try route.withUnsafeBufferPointer { routeBuffer throws(WireEncodeError) in
                try writer.writeRawField(
                    "associatingRoute",
                    ByteSlice(bytes: routeBuffer.baseAddress!, length: routeBuffer.count)
                )
            }
            try writer.endObject()
            return writer.position
        }
        return Array(output.prefix(length))
    }

    private func objectPayload(_ objectID: UUID16) throws(ProtocolError) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 256)
        let length: Int
        do {
            length = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) -> Int in
                var writer = WireCodec(profile: .axoloty1CBOR).writer(
                    buffer: buffer.baseAddress!,
                    capacity: buffer.count
                )
                try writer.beginObject()
                try writer.writeUUIDField("objectId", objectID)
                try writer.writeComma()
                try writeText(&writer, "coreType", "IoSource")
                try writer.writeComma()
                try writeText(&writer, "objectType", "coaty.IoSource")
                try writer.writeComma()
                try writeText(&writer, "name", "parity")
                try writer.endObject()
                return writer.position
            }
        } catch {
            throw ProtocolError(.malformedPayload)
        }
        return Array(output.prefix(length))
    }

    private func objectPayload(fields: [(String, String)]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 256)
        let length = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) -> Int in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: buffer.baseAddress!,
                capacity: buffer.count
            )
            try writer.beginObject()
            for (index, field) in fields.enumerated() {
                if index > 0 { try writer.writeComma() }
                let valueBytes = Array(field.1.utf8)
                try valueBytes.withUnsafeBufferPointer { valueBuffer throws(WireEncodeError) in
                    switch field.0 {
                    case "objectId":
                        try writer.writeStringField(
                            "objectId",
                            ByteSlice(bytes: valueBuffer.baseAddress!, length: valueBuffer.count)
                        )
                    case "coreType":
                        try writer.writeStringField(
                            "coreType",
                            ByteSlice(bytes: valueBuffer.baseAddress!, length: valueBuffer.count)
                        )
                    default:
                        throw .invalidValue
                    }
                }
            }
            try writer.endObject()
            return writer.position
        }
        return Array(output.prefix(length))
    }

    private func writeText(
        _ writer: inout WireWriter,
        _ key: StaticString,
        _ value: String
    ) throws(WireEncodeError) {
        let bytes = Array(value.utf8)
        try bytes.withUnsafeBufferPointer { buffer throws(WireEncodeError) in
            try writer.writeStringField(key, ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
        }
    }
}

// MARK: - Clock

/// A monotonic clock whose sleepers wake only from the test's explicit ticks.
private final class ParityClock: Sendable {
    private struct Sleeper {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var nowMS: UInt64 = 0
        var sleeper: Sleeper?
    }

    private let state = Mutex(State())

    var clock: RuntimePresenceClock {
        RuntimePresenceClock(
            nowMS: { self.state.withLock { $0.nowMS } },
            sleepUntilMS: { deadline in await self.sleep(until: deadline) }
        )
    }

    func tick(at now: UInt64) async throws {
        let woken = state.withLock { state -> Sleeper? in
            precondition(now >= state.nowMS)
            state.nowMS = now
            guard let sleeper = state.sleeper, sleeper.deadline <= now else { return nil }
            state.sleeper = nil
            return sleeper
        }
        woken?.continuation.resume()
        try await withTimeout("presence parity tick at \(now) ms", timeout: .seconds(5)) {
            while !(self.state.withLock { $0.sleeper.map { $0.deadline > now } ?? false }) {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    private func sleep(until deadline: UInt64) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let suspended = state.withLock { state in
                    guard !Task.isCancelled else { return false }
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
