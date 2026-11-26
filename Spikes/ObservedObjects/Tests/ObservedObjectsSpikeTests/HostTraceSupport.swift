// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyObjectModel
import AxolotyWire
@testable import ObservedObjectsSpike

/// Failure classification for the broker-free host trace.
enum HostTraceError: Error, Equatable, Sendable {
    case configuration(String)
    case start(String)
    case encoding(String)
    case timeout(String)
    case cancelled(String)
    case invariant(String)
    case projection(ObjectViewError)
}

/// One stable identifier used by the host trace fixtures.
struct HostTraceIdentity: Sendable, Hashable {
    let uuid: UUID16
    let hyphenated: String

    init(_ hyphenated: String) {
        guard let uuid = UUID16(parsing: hyphenated) else {
            preconditionFailure("host trace fixture uses an invalid UUID: \(hyphenated)")
        }
        self.uuid = uuid
        self.hyphenated = hyphenated
    }
}

/// Fixed identities shared by every profile trace.
enum HostTraceFixture {
    static let namespace = "hosttrace"
    static let runtime = HostTraceIdentity("22222222-2222-4222-8222-222222222222")
    static let responder = HostTraceIdentity("33333333-3333-4333-8333-333333333333")
    static let pump = HostTraceIdentity("55555555-5555-4555-8555-555555555555")
    static let otherPump = HostTraceIdentity("66666666-6666-4666-8666-666666666666")
    static let oldCorrelation = HostTraceIdentity("77777777-7777-4777-8777-777777777777")
    static let newCorrelation = HostTraceIdentity("88888888-8888-4888-8888-888888888888")
    static let emptyCorrelation = HostTraceIdentity("99999999-9999-4999-8999-999999999999")
    static let cancelledCorrelation = HostTraceIdentity("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    static let objectType = "trace.Pump"
    static let objectName = "pump-01"
}

/// Route and payload fixtures for both sealed wire profiles.
enum HostTraceWire {
    enum Event: String {
        case advertise = "ADV"
        case resolve = "RSV"
        case discover = "DSC"
    }

    static func prefix(_ profile: WireProfile) -> String {
        switch profile {
        case .coaty3JSON: return "coaty/3"
        case .axoloty1CBOR: return "axoloty/1"
        }
    }

    static func route(
        profile: WireProfile,
        event: Event,
        source: HostTraceIdentity,
        correlation: HostTraceIdentity? = nil
    ) -> String {
        var route = "\(prefix(profile))/\(HostTraceFixture.namespace)/\(event.rawValue)/\(source.hyphenated)"
        if let correlation {
            route += "/\(correlation.hyphenated)"
        }
        return route
    }

    static func eventType(in route: String) -> String? {
        let levels = route.split(separator: "/", omittingEmptySubsequences: false)
        guard levels.count >= 4 else { return nil }
        return String(levels[3])
    }

    static func correlation(in route: String) -> String? {
        let levels = route.split(separator: "/", omittingEmptySubsequences: false)
        guard levels.count == 6 else { return nil }
        return String(levels[5])
    }

    static func advertisePayload(profile: WireProfile) throws(HostTraceError) -> [UInt8] {
        do {
            let object = try objectPayload(profile: profile, identity: HostTraceFixture.pump)
            return try envelope(profile: profile, field: "object", value: object)
        } catch {
            throw .encoding(String(describing: error))
        }
    }

    static func resolvePayload(
        profile: WireProfile,
        identity: HostTraceIdentity
    ) throws(HostTraceError) -> [UInt8] {
        do {
            let object = try objectPayload(profile: profile, identity: identity)
            return try envelope(profile: profile, field: "object", value: object)
        } catch {
            throw .encoding(String(describing: error))
        }
    }

    static func discoverPayload(
        profile: WireProfile,
        identity: HostTraceIdentity
    ) throws(HostTraceError) -> [UInt8] {
        do {
            var output = [UInt8](repeating: 0, count: 256)
            let length = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) -> Int in
                guard let base = buffer.baseAddress else { throw WireEncodeError.bufferOverflow }
                var writer = WireCodec(profile: profile).writer(buffer: base, capacity: buffer.count)
                try writer.beginObject()
                try writeStringField(&writer, "objectId", identity.hyphenated)
                try writer.endObject()
                return writer.position
            }
            output.removeSubrange(length..<output.count)
            return output
        } catch {
            throw .encoding(String(describing: error))
        }
    }

    /// Returns the `object.objectId` carried by an Advertise or Resolve payload.
    static func objectID(in event: RuntimeEventValue, profile: WireProfile) -> UUID16? {
        objectID(in: event.value, profile: profile)
    }

    static func objectID(in payload: [UInt8], profile: WireProfile) -> UUID16? {
        guard !payload.isEmpty else { return nil }
        let codec = WireCodec(profile: profile)
        return payload.withUnsafeBufferPointer { buffer -> UUID16? in
            guard let base = buffer.baseAddress else { return nil }
            let reader = codec.reader(bytes: base, length: buffer.count)
            guard let object = reader.readField("object") else { return nil }
            return object.withBytes { objectBase, objectLength in
                let objectReader = codec.reader(
                    bytes: objectBase.assumingMemoryBound(to: UInt8.self),
                    length: objectLength
                )
                return objectReader.readUUID("objectId")
            }
        }
    }

    static func objectBytes(in event: RuntimeEventValue, profile: WireProfile) -> [UInt8]? {
        event.value.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            let reader = WireCodec(profile: profile).reader(bytes: base, length: buffer.count)
            guard let object = reader.readField("object"),
                  object.length <= ObjectViewConfiguration.maximumObjectBytes else { return nil }
            return object.ownedBytes()
        }
    }

    /// Returns the exact-ID selector carried by a Discover payload.
    static func discoverObjectID(in payload: [UInt8], profile: WireProfile) -> UUID16? {
        guard !payload.isEmpty else { return nil }
        let codec = WireCodec(profile: profile)
        return payload.withUnsafeBufferPointer { buffer -> UUID16? in
            guard let base = buffer.baseAddress else { return nil }
            let reader = codec.reader(bytes: base, length: buffer.count)
            guard let content = reader.readString("objectId") else { return nil }
            return UUID16(parsing: content)
        }
    }

    private static func objectPayload(
        profile: WireProfile,
        identity: HostTraceIdentity
    ) throws(WireEncodeError) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 256)
        let length = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) -> Int in
            guard let base = buffer.baseAddress else { throw WireEncodeError.bufferOverflow }
            var writer = WireCodec(profile: profile).writer(buffer: base, capacity: buffer.count)
            try writer.beginObject()
            try writeStringField(&writer, "name", HostTraceFixture.objectName)
            try writer.writeComma()
            try writer.writeUUIDField("objectId", identity.uuid)
            try writer.writeComma()
            try writeStringField(&writer, "objectType", HostTraceFixture.objectType)
            try writer.endObject()
            return writer.position
        }
        output.removeSubrange(length..<output.count)
        return output
    }

    private static func envelope(
        profile: WireProfile,
        field: StaticString,
        value: [UInt8]
    ) throws(WireEncodeError) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 256)
        let length = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) -> Int in
            guard let base = buffer.baseAddress else { throw WireEncodeError.bufferOverflow }
            var writer = WireCodec(profile: profile).writer(buffer: base, capacity: buffer.count)
            try writer.beginObject()
            try value.withUnsafeBufferPointer { valueBuffer throws(WireEncodeError) in
                guard let valueBase = valueBuffer.baseAddress else { throw WireEncodeError.invalidValue }
                try writer.writeRawField(
                    field,
                    ByteSlice(bytes: valueBase, length: valueBuffer.count)
                )
            }
            try writer.endObject()
            return writer.position
        }
        output.removeSubrange(length..<output.count)
        return output
    }

    private static func writeStringField(
        _ writer: inout WireWriter,
        _ key: StaticString,
        _ value: String
    ) throws(WireEncodeError) {
        let bytes = Array(value.utf8)
        try bytes.withUnsafeBufferPointer { buffer throws(WireEncodeError) in
            guard let base = buffer.baseAddress else { throw WireEncodeError.invalidValue }
            try writer.writeStringField(key, ByteSlice(bytes: base, length: buffer.count))
        }
    }
}

/// Evidence staged for one correlated window.
struct HostTraceSample: Sendable, Equatable {
    let observation: ObjectObservation
    let correlationID: UUID16
    let epoch: UInt64
    let receiptTimeMS: UInt32
}

/// The example owns the view and binds it to one host feed.
struct HostTraceAttachment {
    private let epoch: UInt64
    private let lossBaseline: HostTraceLossBaseline
    private let session: ObservationSession
    private var view: ObjectView
    private(set) var passiveCoverageLost = false

    init(snapshot: RuntimeDiagnostics) throws(HostTraceError) {
        epoch = snapshot.lifecycle.transportEpoch
        lossBaseline = HostTraceLossBaseline(snapshot)
        do {
            let policy = try ObjectViewConfiguration(staleAfterTicks: 10, retainForTicks: 20)
            var view = try ObjectView(
                watching: [ObjectID(uuid: HostTraceFixture.pump.uuid)],
                configuration: policy,
                profile: snapshot.wireProfile
            )
            session = view.beginSession()
            self.view = view
        } catch {
            throw .projection(error)
        }
    }

    mutating func observe(_ snapshot: RuntimeDiagnostics) throws(HostTraceError) {
        let attachmentChanged = snapshot.lifecycleState != .running || snapshot.lifecycle.transportEpoch != epoch
        guard !passiveCoverageLost, attachmentChanged || lossBaseline.isLossy(snapshot) else { return }
        passiveCoverageLost = true
        do {
            try view.recordContinuityLoss(in: session)
        } catch {
            throw .projection(error)
        }
    }

    mutating func applyPassive(
        _ event: RuntimeEventValue,
        profile: WireProfile,
        within window: ClosedRange<UInt64>
    ) throws(HostTraceError) -> Bool {
        guard !passiveCoverageLost, event.family == .advertise, event.context.provenance == .transport,
              let id = HostTraceWire.objectID(in: event, profile: profile),
              id == HostTraceFixture.pump.uuid,
              let object = HostTraceWire.objectBytes(in: event, profile: profile),
              let tick = receiptTick(event.context.receiptTimeMS, within: window) else { return false }
        try apply(ObjectObservation(
            objectID: ObjectID(uuid: id),
            source: ObjectSource(rawValue: event.context.sourceID),
            delivery: .advertise,
            profile: profile,
            revision: nil,
            bytes: object
        ), at: tick)
        return true
    }

    mutating func apply(_ observation: ObjectObservation, at tick: UInt64) throws(HostTraceError) {
        do {
            try view.apply(observation, in: session, observedAt: tick)
        } catch {
            throw .projection(error)
        }
    }

    func snapshot(at tick: UInt64) -> ObjectSnapshot {
        view.snapshot(for: ObjectID(uuid: HostTraceFixture.pump.uuid), at: tick)
    }
}

/// The bounded counters that make an attempt conservative about loss.
struct HostTraceLossBaseline: Sendable, Equatable {
    let dispatchSaturation: Int
    let ingressSaturation: Int
    let handlerSaturation: Int
    let malformedFrames: Int
    let expiredRequests: Int
    let transportFailures: Int
    let receiveDrops: UInt64
    let oversizedSamples: UInt64
    let presenceResets: UInt64

    init(_ snapshot: RuntimeDiagnostics) {
        self.dispatchSaturation = snapshot.dispatchSaturation
        self.ingressSaturation = snapshot.ingressSaturation
        self.handlerSaturation = snapshot.handlerSaturation
        self.malformedFrames = snapshot.malformedFrames
        self.expiredRequests = snapshot.expiredRequests
        self.transportFailures = snapshot.transportFailures
        self.receiveDrops = snapshot.receiveDrops
        self.oversizedSamples = snapshot.oversizedSamples
        self.presenceResets = snapshot.presenceResets
    }

    /// Reports any loss or continuity counter that moved past this baseline.
    func isLossy(_ snapshot: RuntimeDiagnostics) -> Bool {
        snapshot.dispatchSaturation > dispatchSaturation
            || snapshot.ingressSaturation > ingressSaturation
            || snapshot.handlerSaturation > handlerSaturation
            || snapshot.malformedFrames > malformedFrames
            || snapshot.expiredRequests > expiredRequests
            || snapshot.transportFailures > transportFailures
            || snapshot.receiveDrops > receiveDrops
            || snapshot.oversizedSamples > oversizedSamples
            || snapshot.presenceResets > presenceResets
    }
}

/// Why an attempt was refused or could not be committed.
enum HostTraceInterruption: Sendable, Equatable {
    case notAccepted
    case attemptClosed
    case ignored
    case deadlineExpired
    case notRunning(RuntimeLifecycleState)
    case reset
    case loss
    case rejected(RuntimeRejection)
    case capacityExceeded
    case cancelled
}

/// The result of offering one drained response to an attempt.
enum HostTraceOfferRejection: Sendable, Equatable {
    case attemptClosed
    case deadlineExpired
    case notRunning
    case epochChanged
    case lossy
    case correlationMismatch
    case objectIDMismatch
    case capacityExceeded
}

enum HostTraceOfferResult: Sendable, Equatable {
    case staged
    case coalesced
    case ignored
    case rejected(HostTraceOfferRejection)
}

/// The committed evidence from one reconciliation attempt.
enum HostTraceAttemptOutcome: Sendable, Equatable {
    case admitted(HostTraceSample)
    case noSample
    case conflicting([HostTraceSample])
    case interrupted(HostTraceInterruption)
}

/// One caller-owned reconciliation attempt.
///
/// Reservation happens before submission so an early reply can be staged in
/// the same bounded capacity. A candidate can be admitted only after an
/// accepted receipt, a matching exact object identity and correlation, and a
/// final snapshot that still reports the same running epoch without new loss.
struct HostTraceAttempt: Sendable {
    static let candidateCapacity = 2

    let correlationID: UUID16
    let objectID: UUID16
    let submissionEpoch: UInt64
    let submissionPresenceResets: UInt64
    let baseline: HostTraceLossBaseline
    let deadline: ContinuousClock.Instant
    private(set) var accepted = false
    private(set) var staged: [HostTraceSample] = []
    private(set) var closed = false
    private(set) var interruption: HostTraceInterruption?

    static func reserve(
        correlationID: UUID16,
        objectID: UUID16,
        snapshot: RuntimeDiagnostics,
        deadline: ContinuousClock.Instant
    ) -> Self {
        Self(
            correlationID: correlationID,
            objectID: objectID,
            submissionEpoch: snapshot.lifecycle.transportEpoch,
            submissionPresenceResets: snapshot.presenceResets,
            baseline: HostTraceLossBaseline(snapshot),
            deadline: deadline
        )
    }

    /// Records the receipt returned by the request submission.
    mutating func accept(_ receipt: RuntimeReceipt) -> Bool {
        guard !closed else {
            interruption = .attemptClosed
            return false
        }
        switch receipt {
        case .accepted:
            accepted = true
            return true
        case .ignored:
            interruption = .ignored
            return false
        case .rejected(let rejection):
            interruption = .rejected(rejection)
            return false
        }
    }

    /// Offers one drained response to this attempt.
    mutating func offer(
        _ event: RuntimeEventValue,
        profile: WireProfile,
        snapshot: RuntimeDiagnostics,
        now: ContinuousClock.Instant
    ) -> HostTraceOfferResult {
        guard !closed else { return .rejected(.attemptClosed) }
        guard now <= deadline else {
            interruption = .deadlineExpired
            return .rejected(.deadlineExpired)
        }
        guard snapshot.lifecycleState == .running else {
            interruption = .notRunning(snapshot.lifecycleState)
            return .rejected(.notRunning)
        }
        guard snapshot.lifecycle.transportEpoch == submissionEpoch,
              snapshot.presenceResets == submissionPresenceResets else {
            interruption = .reset
            return .rejected(.epochChanged)
        }
        guard !baseline.isLossy(snapshot) else {
            interruption = .loss
            return .rejected(.lossy)
        }
        guard event.family == .resolve, event.context.provenance == .transport else {
            return .ignored
        }
        guard event.context.correlationID == correlationID else {
            return .rejected(.correlationMismatch)
        }
        guard let observedObjectID = HostTraceWire.objectID(in: event, profile: profile),
              observedObjectID == objectID,
              let bytes = HostTraceWire.objectBytes(in: event, profile: profile) else {
            return .rejected(.objectIDMismatch)
        }
        let sample = HostTraceSample(
            observation: ObjectObservation(
                objectID: ObjectID(uuid: observedObjectID),
                source: ObjectSource(rawValue: event.context.sourceID),
                delivery: .resolve,
                profile: profile,
                revision: nil,
                bytes: bytes
            ),
            correlationID: correlationID,
            epoch: submissionEpoch,
            receiptTimeMS: event.context.receiptTimeMS
        )
        if staged.contains(where: { $0.observation == sample.observation }) {
            return .coalesced
        }
        guard staged.count < Self.candidateCapacity else {
            interruption = .capacityExceeded
            return .rejected(.capacityExceeded)
        }
        staged.append(sample)
        return .staged
    }

    /// Closes the collection window and commits or refuses the attempt.
    mutating func finish(
        snapshot: RuntimeDiagnostics,
        now: ContinuousClock.Instant
    ) -> HostTraceAttemptOutcome {
        guard !closed else { return .interrupted(.attemptClosed) }
        closed = true
        guard accepted else { return .interrupted(interruption ?? .notAccepted) }
        guard now <= deadline else { return .interrupted(.deadlineExpired) }
        guard snapshot.lifecycleState == .running else {
            return .interrupted(.notRunning(snapshot.lifecycleState))
        }
        guard snapshot.lifecycle.transportEpoch == submissionEpoch,
              snapshot.presenceResets == submissionPresenceResets else {
            return .interrupted(.reset)
        }
        guard !baseline.isLossy(snapshot) else { return .interrupted(.loss) }
        if let interruption { return .interrupted(interruption) }
        if staged.isEmpty { return .noSample }
        if staged.count > 1 { return .conflicting(staged) }
        return .admitted(staged[0])
    }

    /// Closes the window without committing a candidate.
    mutating func cancel() -> HostTraceAttemptOutcome {
        guard !closed else { return .interrupted(.attemptClosed) }
        closed = true
        return .interrupted(.cancelled)
    }
}

/// In-process transport with no broker and no network.
actor HostTraceTransport: AxolotyRuntimeTransport {
    nonisolated let profile: WireProfile
    nonisolated var wireProfile: WireProfile { profile }
    nonisolated var capabilities: RuntimeTransportCapabilities { [.activityCounters] }

    private var receive: (@Sendable (RuntimeInboundFrame) -> Void)?
    private var diagnosticsSink: RuntimeTransportDiagnostics?
    private var published: [RuntimeOutboundMessage] = []
    private var startCount = 0

    init(profile: WireProfile) {
        self.profile = profile
    }

    func start(
        receive: @escaping @Sendable (RuntimeInboundFrame) -> Void,
        lastWill: RuntimeTransportLastWill?
    ) async throws(AxolotyError) {
        _ = lastWill
        self.receive = receive
        startCount += 1
        diagnosticsSink?.recordSessionOpen()
        if startCount > 1 {
            diagnosticsSink?.recordReconnect()
        }
    }

    func setFailureHandler(
        _: @escaping @Sendable (RuntimeTransportFailure) -> Void
    ) async {}

    func setDiagnostics(_ diagnostics: RuntimeTransportDiagnostics) async {
        diagnosticsSink = diagnostics
    }

    func perform(_ effect: RuntimeTransportEffect) async throws(AxolotyError) {
        switch effect {
        case .publish(let message):
            guard published.count < 8 else {
                throw AxolotyError.runtime(code: .capacityExceeded, reason: "trace publication limit")
            }
            published.append(message)
            diagnosticsSink?.recordPublishedFrame()
        case .externalRouteActivated, .externalRouteDeactivated:
            break
        }
    }

    func stop() async {
        receive = nil
    }

    func inject(route: String, payload: [UInt8], nowMS: UInt32) {
        diagnosticsSink?.recordReceivedFrame()
        receive?(.profile(route: route, payload: payload, nowMS: nowMS))
    }

    func publishedMessages() -> [RuntimeOutboundMessage] {
        published
    }

    func publishedRoutes() -> [String] {
        published.map(\.route)
    }

    func startCountValue() -> Int {
        startCount
    }

}

/// One composed, stopped-or-running broker-free host runtime.
struct HostTraceHarness: Sendable {
    let runtime: AxolotyRuntime
    let transport: HostTraceTransport
    let advertise: RuntimeEventStream
    let resolve: RuntimeEventStream
    let profile: WireProfile

    func shutdown() async {
        await runtime.stop()
        await runtime.close()
    }
}

/// Creates the deterministic in-process runtime with bounded Advertise and
/// family Resolve streams registered before startup.
func makeHostTraceHarness(
    profile: WireProfile
) async throws(HostTraceError) -> HostTraceHarness {
    let capacities: RuntimeCapacities
    do {
        capacities = try RuntimeCapacities(
            ingress: 16,
            dispatch: 32,
            stream: 8,
            eventStreams: 8,
            protocolMaximumObjects: 16,
            protocolMaximumPendingCorrelations: 4
        )
    } catch {
        throw .configuration(String(describing: error))
    }

    var builder: RuntimeBuilder
    do {
        builder = try RuntimeBuilder(
            sourceID: HostTraceFixture.runtime.uuid,
            namespace: HostTraceFixture.namespace,
            capacities: capacities
        )
    } catch {
        throw .configuration(String(describing: error))
    }

    let advertiseStream: RuntimeEventStream
    let resolveStream: RuntimeEventStream
    do {
        advertiseStream = try builder.events(
            matching: .advertise(objectType: nil),
            buffering: .dropNewest(capacity: 8)
        )
        resolveStream = try builder.events(
            matching: .family(.resolve),
            buffering: .dropNewest(capacity: 8)
        )
    } catch {
        throw .configuration(String(describing: error))
    }

    let definition: RuntimeDefinition
    do {
        definition = try builder.finish()
    } catch {
        throw .configuration(String(describing: error))
    }

    let transport = HostTraceTransport(profile: profile)
    let runtime = AxolotyRuntime(definition: definition, transport: transport)
    do {
        try await runtime.start()
    } catch {
        throw .start(String(describing: error))
    }
    try await hostTraceWait("runtime reaches running", timeout: .seconds(2)) {
        await runtime.state() == .running
    }

    return HostTraceHarness(
        runtime: runtime,
        transport: transport,
        advertise: advertiseStream,
        resolve: resolveStream,
        profile: profile
    )
}

/// Runs one trace and always closes its runtime.
func withHostTraceHarness(
    profile: WireProfile,
    _ body: (HostTraceHarness) async throws(HostTraceError) -> Void
) async throws(HostTraceError) {
    let harness = try await makeHostTraceHarness(profile: profile)
    do {
        try await body(harness)
    } catch {
        await harness.shutdown()
        throw error
    }
    await harness.shutdown()
}

/// Polls a snapshot or transport condition until it holds or the bound expires.
func hostTraceWait(
    _ description: String,
    timeout: Duration = .seconds(2),
    until condition: @escaping @Sendable () async -> Bool
) async throws(HostTraceError) {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() {
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            throw .cancelled(description)
        }
    }
    throw .timeout(description)
}

/// Uses one iterator at a time. A timeout cancels that stream's final read.
func nextHostTraceEvent(
    from stream: RuntimeEventStream,
    timeout: Duration,
    matching predicate: @escaping @Sendable (RuntimeEventValue) -> Bool
) async -> RuntimeEventValue? {
    await withTaskGroup(of: RuntimeEventValue?.self) { group in
        group.addTask {
            for await event in stream where predicate(event) {
                return event
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

func hostTraceNextEvent(
    from stream: RuntimeEventStream,
    matching predicate: @escaping @Sendable (RuntimeEventValue) -> Bool
) async throws(HostTraceError) -> RuntimeEventValue {
    guard let event = await nextHostTraceEvent(from: stream, timeout: .seconds(2), matching: predicate) else {
        throw .timeout("matching runtime event")
    }
    return event
}
