// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Splitting this file is tracked by epic #796
// (https://github.com/phynics/axoloty/issues/796), per the PR #956 review.
// swiftlint:disable file_length

import AxolotyProtocol
import AxolotyObjectModel
@_spi(AxolotyProtocol) import AxolotyWire
import Foundation
import Synchronization

/// Routes transport callbacks into the current bounded ingress stream.
///
/// A transport may retain its receive callback across a soft recovery, while
/// each runtime ingress pump belongs to one transport epoch.
private final class RuntimeTransportIngressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let overflowGate = RuntimeOverflowGate()
    private var continuation: AsyncStream<RuntimeInboundFrame>.Continuation?

    func install(_ continuation: AsyncStream<RuntimeInboundFrame>.Continuation) {
        lock.withLock {
            self.continuation = continuation
            overflowGate.reset()
        }
    }

    func finish() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }

    func yield(_ frame: RuntimeInboundFrame) -> Bool {
        let result = lock.withLock { continuation?.yield(frame) }
        guard case .dropped? = result else { return false }
        return overflowGate.claim()
    }
}

private final class RuntimeTransportNotificationSequence: Sendable {
    private let sequence = Mutex<UInt64>(0)

    func next() -> UInt64 {
        sequence.withLock {
            $0 &+= 1
            return $0
        }
    }
}

// The executor deliberately keeps lifecycle, ingress, dispatch, and handler
// supervision in one serialized owner. Keep this suppression scoped to the
// owner rather than weakening the repository-wide type-size rule.
// swiftlint:disable:next type_body_length
actor ProtocolExecutor {
    private struct LocalPresenceRecord {
        enum Owner { case runtime, application }

        let sourceID: UUID16
        let objectID: UUID16
        let owner: Owner
        let envelope: [UInt8]
        let intervalMS: UInt64
        let phaseMS: UInt64
        var nextRefreshAtMS: UInt64 = 0
        var pendingBatch: RuntimePresencePublicationToken?

        func nextPhase(after nowMS: UInt64) -> UInt64 {
            let offset = (phaseMS + intervalMS - nowMS % intervalMS) % intervalMS
            return nowMS + (offset == 0 ? intervalMS : offset)
        }
    }

    private static let presenceTickMS: UInt64 = 50

    let definition: RuntimeDefinition
    let transport: AxolotyRuntimeTransport
    /// The binding's single wire profile, read once at composition time.
    let wireProfile: WireProfile
    var processor: ProtocolProcessor<64>
    var actionSink = ReusableProtocolActionSink(capacity: 64)
    /// Actions retained for ``conformanceObservation()``. Every other buffer
    /// owned by this executor is capacity-bounded; this one must be too, or a
    /// production runtime that never calls the conformance SPI accumulates one
    /// copied action per dispatched action for the life of the instance. Bound
    /// it to the same dispatch capacity used for the live action sink rather
    /// than an invented constant, and drop the oldest entry once full so a
    /// draining consumer still observes the most recent activity.
    var conformanceActions: [OwnedProtocolAction] = []
    /// One-way operations accepted while the transport is reconnecting.
    /// This queue is bounded by the dispatch capacity and is replayed in
    /// publication order after a successful reconnect.
    private var offlineOperations: [RuntimeOperation] = []
    private var flushingOfflineOperations = false
    var state: RuntimeLifecycleState = .stopped
    private var stopTask: Task<Void, Never>?
    private var terminationWaiter: CheckedContinuation<RuntimeLifecycleState, Never>?
    private var hasStarted = false
    var lifecycleAdvertisementActive = false
    var activeHandlers = 0
    var handlerInFlight: [Int: Int] = [:]
    var nextHandlerID: UInt64 = 1
    var handlerTasks: [UInt64: Task<Void, Never>] = [:]
    private var terminalFailureValue: (AxolotyError.RuntimeErrorCode, String)?
    private var failureTeardownScheduled = false
    private let transportIngressRelay = RuntimeTransportIngressRelay()
    private var recoveryArrivedBeforeFailure = false
    private var softRecoveryConsumed = false
    private var softRecoveryEpoch: UInt64?
    private var transportEpoch: UInt64 = 0
    private var transportCallbackEpoch: UInt64?
    private var recoveredThroughNotification: UInt64 = 0
    private var transportIngressContinuation: AsyncStream<RuntimeInboundFrame>.Continuation?
    private var transportIngressTask: Task<Void, Never>?
    private var outboundContinuation: AsyncStream<RuntimeTransportEffectBatch>.Continuation?
    private var outboundTask: Task<Void, Never>?
    var outboundQueued = 0
    /// Effects handed to the outbound pump that have not yet been confirmed
    /// delivered, in publication order. The pump and this queue stay aligned
    /// until the task has joined. Recovery replays eligible effects from the
    /// queue before admitting new work.
    private var pendingOutboundEffects: [RuntimeQueuedTransportEffect] = []
    private var remainingOutboundCapacity: Int {
        definition.capacities.dispatch - pendingOutboundEffects.count
    }
    /// Exact external routes the transport has confirmed as active.
    ///
    /// `processor.resetTransport()` forgets their associations on failure,
    /// but a soft recovery keeps the transport session and its subscriptions.
    /// `transportRecovered()` releases these routes before peers re-associate.
    /// Bounded by the processor's association capacity; cleared whenever the
    /// transport is stopped.
    private var transportExternalRoutes: [OwnedExternalRouteTransition] = []
    var diagnosticsSnapshotValue = RuntimeDiagnostics()
    private let transportDiagnostics = RuntimeTransportDiagnostics()
    private var diagnosticSequence: UInt64 = 0
    private var pendingRequestCapabilities: [UUID16: ProtocolCapability] = [:]
    private var pendingReconnectCause: RuntimeReconnectCause = .requested
    var typedIoState: RuntimeTypedIoState
    var pendingTypedIoToken: RuntimeTypedIoPublicationToken? = nil
    var typedIoFlushAttempts = 0
    var runtimeModuleTasks: [Task<Void, Never>] = []
    private let eventRegistrations: [RuntimeEventRegistration]

    private let eventStream: AsyncStream<RuntimeEvent>
    let eventContinuation: AsyncStream<RuntimeEvent>.Continuation
    private let diagnosticStream: AsyncStream<RuntimeDiagnostic>
    private let diagnosticContinuation: AsyncStream<RuntimeDiagnostic>.Continuation
    private let presencePolicy: ProtocolPresencePolicy
    private let presenceClock: RuntimePresenceClock
    /// One random owner epoch per runtime instance, not per process.
    private let presenceEpoch: Int
    private var localPresence: [LocalPresenceRecord] = []
    private var nextPresenceBatchID: UInt64 = 0
    private var presenceTask: Task<Void, Never>?
    private var presenceRefreshDeferred = false
    private let presenceExpiryStream: AsyncStream<RuntimePresenceExpiry>
    private let presenceExpiryContinuation: AsyncStream<RuntimePresenceExpiry>.Continuation

    init(
        definition: RuntimeDefinition,
        transport: AxolotyRuntimeTransport,
        presence environment: RuntimePresenceEnvironment
    ) {
        self.definition = definition
        self.transport = transport
        let wireProfile = transport.wireProfile
        self.wireProfile = wireProfile
        self.presencePolicy = wireProfile == .axoloty1CBOR ? definition.presencePolicy : .disabled
        self.presenceClock = environment.clock
        self.presenceEpoch = environment.ownerEpoch ?? Int.random(in: 1...Int(Int32.max))
        if self.presencePolicy == .enabled {
            do {
                self.processor = try ProtocolProcessor<64>(
                    capabilities: definition.capacities.protocolCapabilities,
                    wireCodec: WireCodec(profile: wireProfile),
                    maximumPayloadBytes: definition.capacities.protocolMaximumPayloadBytes,
                    maximumObjects: definition.capacities.protocolMaximumObjects,
                    maximumPendingCorrelations: definition.capacities.protocolMaximumPendingCorrelations,
                    presencePolicy: .enabled
                )
            } catch {
                preconditionFailure("unreachable: axoloty/1 presence composition")
            }
        } else {
            self.processor = ProtocolProcessor<64>(
                capabilities: definition.capacities.protocolCapabilities,
                wireCodec: WireCodec(profile: wireProfile),
                maximumPayloadBytes: definition.capacities.protocolMaximumPayloadBytes,
                maximumObjects: definition.capacities.protocolMaximumObjects,
                maximumPendingCorrelations: definition.capacities.protocolMaximumPendingCorrelations
            )
        }
        self.eventRegistrations = definition.registrations.eventRegistrations
        self.typedIoState = RuntimeTypedIoState(registrations: definition.registrations)
        self.actionSink = ReusableProtocolActionSink(capacity: definition.capacities.dispatch)
        let events = AsyncStream<RuntimeEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(definition.capacities.stream)
        )
        self.eventStream = events.stream
        self.eventContinuation = events.continuation
        let diagnostics = AsyncStream<RuntimeDiagnostic>.makeStream(
            bufferingPolicy: .bufferingOldest(definition.capacities.stream)
        )
        self.diagnosticStream = diagnostics.stream
        self.diagnosticContinuation = diagnostics.continuation
        let presenceExpiries = AsyncStream<RuntimePresenceExpiry>.makeStream(
            bufferingPolicy: .bufferingOldest(definition.capacities.stream)
        )
        self.presenceExpiryStream = presenceExpiries.stream
        self.presenceExpiryContinuation = presenceExpiries.continuation
        if presencePolicy == .disabled { presenceExpiries.continuation.finish() }
        self.diagnosticsSnapshotValue.diagnosticCapacity = definition.capacities.stream
        self.diagnosticsSnapshotValue.capabilities = RuntimeCapabilityInformation(
            protocolCapabilities: definition.capacities.protocolCapabilities,
            transportCapabilities: transport.capabilities,
            wireProfile: wireProfile,
            maximumPayloadBytes: definition.capacities.protocolMaximumPayloadBytes,
            maximumObjects: definition.capacities.protocolMaximumObjects,
            maximumPendingCorrelations: definition.capacities.protocolMaximumPendingCorrelations,
            diagnosticCapacity: definition.capacities.stream
        )
    }

    func start() async -> AxolotyError? {
        switch state {
        case .running:
            return .runtime(code: .notStarted, reason: "runtime is already running")
        case .closed:
            return .runtime(code: .notStarted, reason: "runtime is closed")
        case .starting, .reconnecting, .stopping:
            return .runtime(code: .notStarted, reason: "runtime lifecycle transition is already in progress")
        case .failed:
            return .runtime(code: .notStarted, reason: "runtime failed; stop it before restarting")
        case .stopped:
            guard !hasStarted else {
                return .runtime(code: .notStarted, reason: "runtime instances are single-use; construct a new instance")
            }
            break
        }
        if definition.presence != nil, wireProfile != .axoloty1CBOR {
            return .invalidConfiguration(
                option: "presence",
                reason: "soft-state presence requires the axoloty/1 profile"
            )
        }
        hasStarted = true
        recoveryArrivedBeforeFailure = false
        softRecoveryConsumed = false
        transition(to: .starting)
        transportEpoch &+= 1
        let epoch = transportEpoch
        installTransportIngressPump(epoch: epoch)
        installOutboundPump()
        do {
            let lastWill = try makeTransportLastWill()
            await transport.setDiagnostics(transportDiagnostics)
            await installTransportCallbacks(epoch: epoch)
            // A stop may have advanced the epoch while the callbacks were
            // installed. Starting now would open a connection after the host
            // already stopped.
            guard state == .starting, transportEpoch == epoch else {
                return .runtime(code: .notStarted, reason: "runtime start was superseded before the transport started")
            }
            try await transport.start(
                receive: transportReceiveHandler(),
                lastWill: lastWill
            )
            guard state == .starting, transportEpoch == epoch else {
                await transport.stop()
                return .runtime(code: .notStarted, reason: "runtime start was superseded by another lifecycle transition")
            }
            try await transport.activateProfileInterest(namespace: definition.namespace)
            guard state == .starting, transportEpoch == epoch else {
                await transport.stop()
                return .runtime(
                    code: .notStarted,
                    reason: "runtime start was superseded while activating profile interest"
                )
            }
            if presencePolicy == .enabled {
                try await announceRuntimePresence(nowMS: presenceClock.nowMS())
            } else {
                try await publishLifecycleAdvertisement(nowMS: monotonicNowMS())
                try await publishIoAdvertisements(nowMS: monotonicNowMS())
            }
            guard state == .starting, transportEpoch == epoch else {
                await transport.stop()
                return .runtime(code: .notStarted, reason: "runtime start was superseded during advertisement")
            }
            transition(to: .running)
            if presencePolicy == .enabled {
                startPresenceTimer(nowMS: presenceClock.nowMS())
            }
            await startRuntimeModules()
            return nil
        } catch {
            // A concurrent stop/close may have advanced the epoch while the
            // transport was suspended. Preserve that terminal transition
            // instead of resurrecting the runtime as failed.
            if state == .starting, transportEpoch == epoch {
                let detail = runtimeErrorDetail(error)
                failRuntime(
                    code: .brokerUnavailable,
                    detail: detail,
                    diagnostic: .transportFailed,
                    observation: .transportFailure(RuntimeTransportObservation(
                        code: .brokerUnavailable,
                        detail: detail
                    ))
                )
            }
            return .runtime(code: .brokerUnavailable, reason: runtimeErrorDetail(error))
        }
    }

    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard state == .running || state == .starting || state == .reconnecting || state == .failed else { return }
        let allowModulePublications = state == .running
        transportEpoch &+= 1
        let epoch = transportEpoch
        transportCallbackEpoch = nil
        transition(to: .stopping)
        presenceTask?.cancel()
        cancelIngressPump()
        // Stop and close callers share a teardown task that outlives any
        // caller's cancellation.
        let task = Task { await performStop(epoch: epoch, allowModulePublications: allowModulePublications) }
        stopTask = task
        await task.value
    }

    private func performStop(epoch: UInt64, allowModulePublications: Bool) async {
        await stopPresenceTimer(epoch: epoch)
        await stopRuntimeModules(allowPublications: allowModulePublications)
        offlineOperations.removeAll(keepingCapacity: true)
        await cancelAndDrainHandlers()
        typedIoState.clearTransportState()
        finishIoObservers()
        let drainBeforeClose = presencePolicy == .enabled || lifecycleAdvertisementActive || typedIoState.hasEndpoints
            || !definition.registrations.modules.isEmpty
        if drainBeforeClose {
            finishOutboundPump()
            await joinOutboundPump(epoch: epoch)
            do {
                try await withdrawApplicationPresence()
                try await publishIoDeadvertisements(nowMS: monotonicNowMS())
                try await publishLifecycleDeadvertisement(nowMS: monotonicNowMS())
            } catch {
                emitTransportFailure(error)
            }
        }
        do {
            try await transport.deactivateProfileInterest(namespace: definition.namespace)
        } catch {
            emitTransportFailure(error)
        }
        await transport.stop()
        transportExternalRoutes.removeAll()
        if !drainBeforeClose {
            finishOutboundPump()
            await joinOutboundPump(epoch: epoch)
        }
        pendingOutboundEffects.removeAll()
        outboundQueued = 0
        localPresence.removeAll()
        presenceExpiryContinuation.finish()
        transition(to: .stopped)
        signalTermination()
        stopTask = nil
    }

    func close() async {
        await stop()
        guard state != .closed else { return }
        transition(to: .closed)
        signalTermination()
        finishIoObservers()
        for registration in eventRegistrations {
            registration.continuation.finish()
        }
        eventContinuation.finish()
        diagnosticContinuation.finish()
        presenceExpiryContinuation.finish()
    }

    func reconnect() async {
        guard !Task.isCancelled, state == .running || state == .reconnecting else { return }
        transition(to: .reconnecting)
        recoveryArrivedBeforeFailure = false
        softRecoveryConsumed = false
        softRecoveryEpoch = nil
        transportEpoch &+= 1
        let epoch = transportEpoch
        transportCallbackEpoch = nil
        suspendTransport(.requested)
        var attemptedStart = false
        do {
            await stopPresenceTimer(epoch: epoch)
            guard reconnectAttemptIsCurrent(epoch) else { return }
            try Task.checkCancellation()
            let lastWill = try makeTransportLastWill()
            await joinOutboundPump(epoch: epoch)
            guard reconnectAttemptIsCurrent(epoch) else { return }
            try Task.checkCancellation()
            // A broker-side close can race this explicit reconnect.  The
            // binding may therefore already have lost its subscription
            // session; deactivation is best-effort in that path and fresh
            // profile-interest activation below is authoritative.
            try? await transport.deactivateProfileInterest(namespace: definition.namespace)
            guard reconnectAttemptIsCurrent(epoch) else { return }
            try Task.checkCancellation()
            await transport.stop()
            guard reconnectAttemptIsCurrent(epoch) else { return }
            try Task.checkCancellation()
            transportExternalRoutes.removeAll()
            installTransportIngressPump(epoch: epoch)
            installOutboundPump()
            await installTransportCallbacks(epoch: epoch)
            // A stop or a newer lifecycle transition may have advanced the
            // epoch while the callbacks were installed. Starting the transport
            // here would then open a connection the host already stopped.
            guard reconnectAttemptIsCurrent(epoch) else { return }
            try Task.checkCancellation()
            attemptedStart = true
            try await transport.start(
                receive: transportReceiveHandler(),
                lastWill: lastWill
            )
            guard reconnectAttemptIsCurrent(epoch) else { return }
            try Task.checkCancellation()
            try await finishTransportRecovery(
                epoch: epoch,
                activateProfileInterest: true,
                cause: .requested
            )
            try Task.checkCancellation()
        } catch {
            guard reconnectAttemptIsCurrent(epoch) else { return }
            if Task.isCancelled {
                // Discard notifications queued by this attempt before closing
                // its connection. The runtime remains suspended and retryable.
                transportCallbackEpoch = nil
                if attemptedStart { await transport.stop() }
                return
            }
            // A transport failure while recovering is no more terminal than one
            // during normal operation. `transportFailed(_:)` deliberately parks
            // the executor in `.reconnecting` so the caller can restore the
            // network path and invoke `reconnect()` again; failing the runtime
            // here contradicted that contract and destroyed a recoverable
            // instance the first time a restarted broker was not yet accepting
            // connections. Stay `.reconnecting` and report the attempt so the
            // caller can retry.
            diagnosticsSnapshotValue.transportFailures += 1
            emitTransportFailure(error)
        }
    }

    /// Whether this reconnect attempt still owns the lifecycle and transport.
    private func reconnectAttemptIsCurrent(_ epoch: UInt64) -> Bool {
        state == .reconnecting && transportEpoch == epoch
    }

    private func suspendTransport(_ cause: RuntimeReconnectCause) {
        presenceTask?.cancel()
        if presencePolicy == .enabled {
            processor.suspendPresence()
        } else {
            processor.resetTransport()
        }
        resetTransportPresence()
        cancelPendingRequestsForTransportReset()
        clearIoTransportState()
        recordReconnectStart(cause)
        cancelIngressPump()
        finishOutboundPump(cancel: true)
    }

    private func installTransportCallbacks(epoch: UInt64) async {
        guard epoch == transportEpoch else { return }
        let notifications = RuntimeTransportNotificationSequence()
        await transport.setFailureHandler { [weak self] failure in
            let notification = notifications.next()
            Task { await self?.transportDidFail(failure, callbackEpoch: epoch, notification: notification) }
        }
        guard epoch == transportEpoch else { return }
        await transport.setRecoveryHandler { [weak self] in
            let notification = notifications.next()
            Task { await self?.transportDidRecover(callbackEpoch: epoch, notification: notification) }
        }
        guard epoch == transportEpoch else { return }
        recoveredThroughNotification = 0
        transportCallbackEpoch = epoch
    }

    private func transportDidFail(
        _ failure: RuntimeTransportFailure,
        callbackEpoch: UInt64,
        notification: UInt64
    ) async {
        // Callback tasks can reach the executor out of order. A loss reported
        // before an accepted soft recovery belongs to the interrupted session.
        guard transportCallbackEpoch == callbackEpoch, notification > recoveredThroughNotification else { return }
        await transportFailed(failure)
    }

    private func transportDidRecover(callbackEpoch: UInt64, notification: UInt64) async {
        guard transportCallbackEpoch == callbackEpoch, notification > recoveredThroughNotification else { return }
        await transportRecovered(notification: notification)
    }

    /// The bounded stream of peer objects removed by presence expiry.
    func presenceExpiries() -> AsyncStream<RuntimePresenceExpiry> { presenceExpiryStream }

    /// Publishes one local object with a presence lease and retains it for refresh.
    func advertisePresence(objectID: UUID16, object: [UInt8], leaseMS: UInt32) -> RuntimeReceipt {
        guard presencePolicy == .enabled else {
            return .rejected(.protocol(.unsupportedCapability))
        }
        guard state == .running else { return .rejected(.notRunning(state)) }
        guard (1_000...3_600_000).contains(leaseMS) else {
            return .rejected(.malformedPayload)
        }
        let maximumPayloadBytes = definition.capacities.protocolMaximumPayloadBytes
        guard object.count <= maximumPayloadBytes else { return .rejected(.capacityExceeded) }
        let encodedID = object.withUnsafeBufferPointer { buffer -> UUID16? in
            guard let base = buffer.baseAddress else { return nil }
            return WireCodec(profile: wireProfile).reader(bytes: base, length: buffer.count).readUUID("objectId")
        }
        guard encodedID == objectID else { return .rejected(.malformedPayload) }
        guard definition.identity?.id != objectID,
              !definition.registrations.ioEndpointRegistrations.contains(where: { $0.id.uuid == objectID }) else {
            return .rejected(.protocol(.duplicate))
        }
        let envelope: [UInt8]
        do {
            envelope = try RuntimeWirePayload.advertiseEnvelope(
                object: object,
                leaseMS: Int(leaseMS),
                ownerEpoch: presenceEpoch,
                profile: wireProfile,
                capacity: maximumPayloadBytes
            )
        } catch {
            return .rejected(error.code == .capacityExceeded ? .capacityExceeded : .malformedPayload)
        }
        if let held = localPresence.first(where: { $0.objectID == objectID }) {
            return held.envelope == envelope ? .accepted : .rejected(.protocol(.duplicate))
        }
        guard localPresence.count < definition.capacities.protocolMaximumObjects else {
            return .rejected(.capacityExceeded)
        }
        let intervalMS = presenceRefreshIntervalMS(leaseMS: leaseMS)
        let record = LocalPresenceRecord(
            sourceID: definition.sourceID,
            objectID: objectID,
            owner: .application,
            envelope: envelope,
            intervalMS: intervalMS,
            phaseMS: runtimePresencePhase(
                sourceID: definition.sourceID,
                objectID: objectID,
                intervalMS: intervalMS
            )
        )
        return publishPresenceAdvertisement(record, refreshIndex: nil, nowMS: presenceClock.nowMS())
    }

    private func presenceRefreshIntervalMS(leaseMS: UInt32) -> UInt64 {
        max(Self.presenceTickMS, UInt64(leaseMS) * 2 / 9)
    }

    private func presenceAdvertisementError(_ error: ProtocolError) -> AxolotyError {
        error.code == .capacityExceeded
            ? .runtime(code: .capacityExceeded, reason: "presence advertisement exceeds the payload bound")
            : .invalidConfiguration(option: "presence", reason: "presence advertisement could not be encoded")
    }

    /// Announces the identity and typed IO endpoints with the configured
    /// presence lease and installs their refresh records.
    ///
    /// - Parameter nowMS: The presence clock time used for the refresh phase.
    /// - Throws: ``AxolotyError`` when an envelope cannot be built or published.
    private func announceRuntimePresence(nowMS: UInt64) async throws(AxolotyError) {
        guard let configuration = definition.presence, presencePolicy == .enabled else { return }
        let maximumPayloadBytes = definition.capacities.protocolMaximumPayloadBytes
        var announcements: [(sourceID: UUID16, objectID: UUID16, envelope: [UInt8])] = []
        if let identity = definition.identity {
            do {
                let envelope = try RuntimeWirePayload.cborAdvertise(
                    identity: identity,
                    leaseMS: Int(configuration.leaseMS),
                    ownerEpoch: presenceEpoch,
                    capacity: maximumPayloadBytes
                )
                announcements.append((identity.id, identity.id, envelope))
            } catch {
                throw presenceAdvertisementError(error)
            }
        }
        for endpoint in typedIoState.endpointRegistrations {
            do {
                let envelope = try runtimeAdvertisePayload(
                    objectBytes: endpoint.objectBytes,
                    profile: wireProfile,
                    leaseMS: Int(configuration.leaseMS),
                    ownerEpoch: presenceEpoch,
                    capacity: maximumPayloadBytes
                )
                announcements.append((endpoint.id.uuid, endpoint.id.uuid, envelope))
            } catch {
                throw presenceAdvertisementError(error)
            }
        }
        localPresence.removeAll { $0.owner == .runtime }
        guard localPresence.count + announcements.count <= definition.capacities.protocolMaximumObjects else {
            throw .runtime(code: .capacityExceeded, reason: "the presence table is full")
        }
        let intervalMS = presenceRefreshIntervalMS(leaseMS: configuration.leaseMS)
        presenceRefreshDeferred = false
        for announcement in announcements {
            let operation = RuntimeOperation.advertise(sourceID: announcement.sourceID, payload: announcement.envelope)
            try await publishLifecycle(operation, nowMS: UInt32(truncatingIfNeeded: nowMS))
            var record = LocalPresenceRecord(
                sourceID: announcement.sourceID,
                objectID: announcement.objectID,
                owner: .runtime,
                envelope: announcement.envelope,
                intervalMS: intervalMS,
                phaseMS: runtimePresencePhase(
                    sourceID: announcement.sourceID,
                    objectID: announcement.objectID,
                    intervalMS: intervalMS
                )
            )
            record.nextRefreshAtMS = record.nextPhase(after: nowMS)
            localPresence.append(record)
        }
        lifecycleAdvertisementActive = definition.identity != nil
    }

    private func publishPresenceAdvertisement(
        _ record: LocalPresenceRecord,
        refreshIndex: Int?,
        nowMS: UInt64
    ) -> RuntimeReceipt {
        guard outboundContinuation != nil, remainingOutboundCapacity > 0 else {
            return .rejected(.capacityExceeded)
        }
        let operation = RuntimeOperation.advertise(sourceID: record.sourceID, payload: record.envelope)
        let token = RuntimePresencePublicationToken(
            sourceID: record.sourceID,
            objectID: record.objectID,
            transportEpoch: transportEpoch,
            batchID: nextPresenceBatchID
        )
        let isAnnouncement = refreshIndex == nil
        let outcome = processOutboundOperation(
            operation,
            nowMS: UInt32(truncatingIfNeeded: nowMS),
            maximumActionCount: remainingOutboundCapacity
        ) {
            var scheduled = record
            scheduled.nextRefreshAtMS = record.nextPhase(after: nowMS)
            scheduled.pendingBatch = token
            if let refreshIndex {
                localPresence[refreshIndex] = scheduled
            } else {
                localPresence.append(scheduled)
            }
            nextPresenceBatchID &+= 1
            dispatchActions(nowMS: isAnnouncement ? monotonicNowMS() : 0, presence: (token, isAnnouncement))
        }
        let receipt = receipt(for: outcome)
        if isAnnouncement {
            eventContinuation.yield(.transition(receipt))
            if case .accepted = receipt { recordLocalPresence(operation) }
        }
        return receipt
    }

    private func startPresenceTimer(nowMS: UInt64) {
        guard state == .running else { return }
        presenceTask?.cancel()
        let epoch = transportEpoch
        presenceTask = Task { [weak self, clock = presenceClock] in
            var deadline = nowMS + Self.presenceTickMS
            while !Task.isCancelled {
                await clock.sleepUntilMS(deadline)
                guard !Task.isCancelled, let now = await self?.presenceTick(epoch: epoch) else { return }
                // Keep the cadence anchored when the executor misses ticks.
                let elapsedTicks = (max(now, deadline) - deadline) / Self.presenceTickMS
                deadline += (elapsedTicks + 1) * Self.presenceTickMS
            }
        }
    }

    private func stopPresenceTimer(epoch: UInt64) async {
        let task = presenceTask
        task?.cancel()
        await task?.value
        guard transportEpoch == epoch else { return }
        presenceTask = nil
    }

    private func presenceTick(epoch: UInt64) -> UInt64? {
        guard !Task.isCancelled, state == .running, transportEpoch == epoch else { return nil }
        let nowMS = presenceClock.nowMS()
        expirePeerPresence(nowMS: UInt32(truncatingIfNeeded: nowMS))
        publishDuePresence(nowMS: nowMS)
        return nowMS
    }

    /// Publishes every due refresh that fits the outbound budget.
    ///
    /// A capacity rejection leaves the record due and marks the refresh
    /// deferred so the outbound pump retries it when it frees a slot.
    private func publishDuePresence(nowMS: UInt64) {
        presenceRefreshDeferred = false
        let due = localPresence.indices.filter { index in
            let record = localPresence[index]
            return record.pendingBatch == nil && record.nextRefreshAtMS <= nowMS
        }.sorted { localPresence[$0].nextRefreshAtMS < localPresence[$1].nextRefreshAtMS }
        for index in due {
            guard state == .running, remainingOutboundCapacity > 0 else {
                presenceRefreshDeferred = true
                break
            }
            let receipt = publishPresenceAdvertisement(localPresence[index], refreshIndex: index, nowMS: nowMS)
            if case .rejected(.capacityExceeded) = receipt {
                presenceRefreshDeferred = true
                break
            }
        }
    }

    private func expirePeerPresence(nowMS: UInt32) {
        var removed = false
        for _ in 0..<definition.capacities.protocolMaximumObjects {
            guard let expired = processor.expirePresence(nowMS: nowMS) else { break }
            removed = true
            let result = presenceExpiryContinuation.yield(RuntimePresenceExpiry(
                sourceID: expired.sourceID,
                objectID: expired.objectID,
                atMS: nowMS
            ))
            if case .dropped = result { diagnosticsSnapshotValue.presenceExpiriesDropped &+= 1 }
        }
        if removed {
            diagnosticsSnapshotValue.presenceGeneration = processor.state.generation
        }
    }

    private func resumePresence(nowMS: UInt64) {
        processor.resumePresence(nowMS: UInt32(truncatingIfNeeded: nowMS))
        presenceRefreshDeferred = false
        for index in localPresence.indices {
            localPresence[index].pendingBatch = nil
            localPresence[index].nextRefreshAtMS = localPresence[index].nextPhase(after: nowMS)
        }
    }

    /// Withdraws application-owned leases in declaration order.
    ///
    /// Runtime-owned identity and typed IO withdrawals follow separately so
    /// stop keeps its established ordering.
    ///
    /// - Throws: ``AxolotyError`` at the first transport failure so a dead
    ///   transport does not wait for one publish timeout per record.
    private func withdrawApplicationPresence() async throws(AxolotyError) {
        for record in localPresence where record.owner == .application {
            try await publishDeadvertisement(
                objectID: record.objectID,
                sourceID: definition.sourceID,
                nowMS: monotonicNowMS()
            )
        }
    }

    private func ingressOverflow() {
        guard state == .running else { return }
        diagnosticsSnapshotValue.ingressSaturation += 1
        failRuntime(
            code: .capacityExceeded,
            detail: "transport ingress queue is full",
            diagnostic: .capacityExceeded,
            observation: .admission(RuntimeAdmissionObservation(
                resource: .ingress,
                outcome: .rejected,
                capacity: definition.capacities.ingress
            ))
        )
    }

    private func installTransportIngressPump(epoch: UInt64) {
        let ingressPipe = AsyncStream<RuntimeInboundFrame>.makeStream(
            bufferingPolicy: .bufferingOldest(definition.capacities.ingress)
        )
        transportIngressContinuation = ingressPipe.continuation
        transportIngressRelay.install(ingressPipe.continuation)
        transportIngressTask = Task { [weak self, stream = ingressPipe.stream] in
            for await frame in stream {
                guard !Task.isCancelled else { break }
                await self?.receiveTransport(frame, epoch: epoch)
            }
        }
    }

    private func transportReceiveHandler() -> @Sendable (RuntimeInboundFrame) -> Void {
        { [weak self, ingressRelay = transportIngressRelay] frame in
            if ingressRelay.yield(frame) {
                Task { await self?.ingressOverflow() }
            }
        }
    }

    private func finishTransportRecovery(
        epoch: UInt64,
        activateProfileInterest: Bool,
        cause: RuntimeReconnectCause
    ) async throws {
        guard !Task.isCancelled, reconnectAttemptIsCurrent(epoch) else { return }
        if activateProfileInterest {
            try await transport.activateProfileInterest(namespace: definition.namespace)
            guard !Task.isCancelled, reconnectAttemptIsCurrent(epoch) else { return }
        }
        let presenceReadyMS = presencePolicy == .enabled ? presenceClock.nowMS() : nil
        if let presenceReadyMS {
            try await announceRuntimePresence(nowMS: presenceReadyMS)
        } else {
            try await publishLifecycleAdvertisement(nowMS: monotonicNowMS())
            guard !Task.isCancelled, reconnectAttemptIsCurrent(epoch) else { return }
            try await publishIoAdvertisements(nowMS: monotonicNowMS())
        }
        guard !Task.isCancelled, reconnectAttemptIsCurrent(epoch) else { return }
        if let presenceReadyMS { resumePresence(nowMS: presenceReadyMS) }
        transition(to: .running)
        softRecoveryConsumed = true
        emitReconnectCompletion(cause: cause)
        // Replay effects that were accepted before failure ahead of work
        // accepted while reconnecting, preserving publication order.
        replayQueuedOutboundEffects()
        flushOfflineOperations(nowMS: monotonicNowMS())
        if let presenceReadyMS { startPresenceTimer(nowMS: presenceReadyMS) }
        await startRuntimeModules(restarting: true)
    }

    private func transportRecovered(notification: UInt64? = nil) async {
        guard state == .running || state == .reconnecting else { return }
        guard state == .reconnecting else {
            guard !softRecoveryConsumed, !recoveryArrivedBeforeFailure else { return }
            recoveryArrivedBeforeFailure = true
            return
        }
        guard !softRecoveryConsumed, softRecoveryEpoch == nil else { return }
        if let notification { recoveredThroughNotification = notification }
        // The recovered session can supersede an explicit reconnect. Its
        // pumps and timer must belong to a distinct epoch.
        transportEpoch &+= 1
        let epoch = transportEpoch
        softRecoveryEpoch = epoch
        defer { if softRecoveryEpoch == epoch { softRecoveryEpoch = nil } }
        finishOutboundPump(cancel: true)
        await stopPresenceTimer(epoch: epoch)
        guard reconnectAttemptIsCurrent(epoch) else { return }
        await cancelAndDrainIngressPump()
        guard reconnectAttemptIsCurrent(epoch) else { return }
        await joinOutboundPump(epoch: epoch)
        guard reconnectAttemptIsCurrent(epoch) else { return }
        installTransportIngressPump(epoch: epoch)
        installOutboundPump()
        do {
            try await releaseRetainedExternalRoutes(epoch: epoch)
            try await finishTransportRecovery(
                epoch: epoch,
                activateProfileInterest: false,
                cause: pendingReconnectCause
            )
        } catch {
            guard state == .reconnecting, transportEpoch == epoch else { return }
            diagnosticsSnapshotValue.transportFailures += 1
            emitTransportFailure(error)
        }
    }

    /// Releases exact external routes that a soft-recovered transport still
    /// holds after `processor.resetTransport()` forgot their associations.
    ///
    /// Without this, each recovery episode would leave one subscription (or
    /// reference) per active route behind, and repeated recoveries would
    /// exhaust the transport's bounded external-route table.
    private func releaseRetainedExternalRoutes(epoch: UInt64) async throws {
        while let transition = transportExternalRoutes.last {
            try await transport.perform(.externalRouteDeactivated(transition))
            guard state == .reconnecting, transportEpoch == epoch else { return }
            transportExternalRoutes.removeLast()
        }
    }

    /// Applies one lifecycle transition and records owned observation state.
    private func transition(to next: RuntimeLifecycleState) {
        let previous = state
        guard previous != next else { return }
        state = next
        let observation = RuntimeLifecycleObservation(
            from: previous,
            to: next,
            transportEpoch: transportEpoch
        )
        diagnosticsSnapshotValue.lifecycle = observation
    }

    private func recordReconnectStart(_ cause: RuntimeReconnectCause) {
        diagnosticsSnapshotValue.reconnects += 1
        pendingReconnectCause = cause
        diagnosticsSnapshotValue.lastReconnect = RuntimeReconnectObservation(
            cause: cause,
            attempt: UInt64(diagnosticsSnapshotValue.reconnects),
            transportEpoch: transportEpoch
        )
    }

    private func emitReconnectCompletion(cause: RuntimeReconnectCause) {
        let observation = RuntimeReconnectObservation(
            cause: cause,
            attempt: UInt64(diagnosticsSnapshotValue.reconnects),
            transportEpoch: transportEpoch
        )
        diagnosticsSnapshotValue.lastReconnect = observation
        emit(RuntimeDiagnostic(
            kind: .reconnected,
            detail: "transport reconnected",
            sequence: 0,
            timestampMS: 0,
            observation: .reconnect(observation)
        ))
    }

    private func resetTransportPresence() {
        diagnosticsSnapshotValue.presenceUncertain = true
        diagnosticsSnapshotValue.presenceResets += 1
        diagnosticsSnapshotValue.activeObjects = processor.state.activeObjects
        diagnosticsSnapshotValue.presenceGeneration = processor.state.generation
        let observation = RuntimePresenceObservation(
            sourceID: nil,
            objectID: nil,
            evidence: .transportReset,
            activeObjects: processor.state.activeObjects,
            generation: processor.state.generation
        )
        diagnosticsSnapshotValue.lastPresence = observation
        emit(RuntimeDiagnostic(
            kind: .presenceChanged,
            detail: "transport reset made peer presence uncertain",
            sequence: 0,
            timestampMS: 0,
            observation: .presence(observation)
        ))
    }

    private func cancelPendingRequestsForTransportReset() {
        let cancelled = pendingRequestCapabilities
        pendingRequestCapabilities.removeAll(keepingCapacity: true)
        for (correlationID, capability) in cancelled {
            diagnosticsSnapshotValue.cancelledRequests &+= 1
            emit(RuntimeDiagnostic(
                kind: .requestCancelled,
                detail: "request cancelled by transport reset",
                sequence: 0,
                timestampMS: 0,
                observation: .request(RuntimeRequestObservation(
                    capability: capability,
                    correlationID: correlationID,
                    outcome: .cancelled
                ))
            ))
        }
        diagnosticsSnapshotValue.pendingRequests = processor.state.pendingCorrelations
    }

    func lifecycleState() -> RuntimeLifecycleState { state }

    /// Waits for the executor to reach a terminal lifecycle state.
    ///
    /// The waiter is owned by this actor so ``stop()`` and failure teardown
    /// wake ``run()`` without a polling task or a second lifecycle owner.
    func waitForTermination() async -> RuntimeLifecycleState {
        if let terminalState = terminationState() {
            return terminalState
        }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if let terminalState = self.terminationState() {
                    continuation.resume(returning: terminalState)
                } else {
                    self.terminationWaiter = continuation
                }
            }
        }, onCancel: {
            Task { [weak self] in
                await self?.cancelTerminationWaiter()
            }
        })
    }

    private func terminationState() -> RuntimeLifecycleState? {
        switch state {
        case .failed, .stopped, .closed: return state
        case .starting, .running, .reconnecting, .stopping: return nil
        }
    }

    private func signalTermination() {
        guard let waiter = terminationWaiter, let terminalState = terminationState() else { return }
        terminationWaiter = nil
        waiter.resume(returning: terminalState)
    }

    private func cancelTerminationWaiter() {
        guard let waiter = terminationWaiter else { return }
        terminationWaiter = nil
        waiter.resume(returning: state)
    }

    func runtimeState() -> RuntimeState {
        switch state {
        case .stopped: return hasStarted ? .stopped : .initialized
        case .starting: return .starting
        case .running: return .running
        case .reconnecting: return .reconnecting
        case .stopping: return .stopping
        case .failed: return .failed
        case .closed: return .closed
        }
    }

    func sourceID() -> UUID16 { definition.sourceID }

    func events() -> AsyncStream<RuntimeEvent> { eventStream }

    func diagnostics() -> AsyncStream<RuntimeDiagnostic> { diagnosticStream }
    func diagnosticsSnapshot() -> RuntimeDiagnostics {
        var snapshot = diagnosticsSnapshotValue
        let transport = transportDiagnostics.snapshot()
        snapshot.receivedFrames = transport.receivedFrames
        snapshot.publishedFrames = transport.publishedFrames
        snapshot.receiveDrops = transport.receiveDrops
        snapshot.oversizedSamples = transport.oversizedSamples
        snapshot.sessionOpens = transport.sessionOpens
        snapshot.sessionFailures = transport.sessionFailures
        snapshot.transportReconnects = transport.reconnects
        snapshot.activeExternalSubscriptions = transport.activeExternalSubscriptions
        let processorState = processor.state
        snapshot.pendingRequests = processorState.pendingCorrelations
        snapshot.activeObjects = processorState.activeObjects
        if snapshot.lastPresence == nil {
            snapshot.presenceGeneration = processorState.generation
        }
        snapshot.diagnosticSequence = diagnosticSequence
        snapshot.diagnosticCapacity = definition.capacities.stream
        return snapshot
    }

    func terminalFailure() -> (AxolotyError.RuntimeErrorCode, String)? { terminalFailureValue }

    func expire(nowMS: UInt32) -> Bool {
        guard state == .running else { return false }
        let before = pendingCorrelationIDs()
        guard processor.expire(nowMS: nowMS) else { return false }
        let after = pendingCorrelationIDs()
        let afterSet = Set(after)
        for correlationID in before where !afterSet.contains(correlationID) {
            let capability = pendingRequestCapabilities.removeValue(forKey: correlationID)
            diagnosticsSnapshotValue.expiredRequests += 1
            emit(RuntimeDiagnostic(
                kind: .requestExpired,
                detail: "request deadline expired",
                sequence: 0,
                timestampMS: 0,
                observation: .request(RuntimeRequestObservation(
                    capability: capability,
                    correlationID: correlationID,
                    outcome: .expired
                ))
            ))
        }
        diagnosticsSnapshotValue.pendingRequests = after.count
        return true
    }

    func cancel(correlationID: UUID16, duringModuleShutdown: Bool = false) -> Bool {
        guard admitsLocalWork(duringModuleShutdown: duringModuleShutdown) else { return false }
        guard processor.cancel(correlationID: correlationID) else { return false }
        let capability = pendingRequestCapabilities.removeValue(forKey: correlationID)
        diagnosticsSnapshotValue.cancelledRequests &+= 1
        diagnosticsSnapshotValue.pendingRequests = processor.state.pendingCorrelations
        emit(RuntimeDiagnostic(
            kind: .requestCancelled,
            detail: "request cancelled",
            sequence: 0,
            timestampMS: 0,
            observation: .request(RuntimeRequestObservation(
                capability: capability,
                correlationID: correlationID,
                outcome: .cancelled
            ))
        ))
        return true
    }

    private func pendingCorrelationIDs() -> [UUID16] {
        var projection = ProtocolFixedStateSnapshot<64>()
        processor.copyState(into: &projection)
        var identities: [UUID16] = []
        identities.reserveCapacity(projection.pendingCorrelationCount)
        for index in 0..<projection.pendingCorrelationCount {
            if let identity = projection.pendingCorrelationIDs[index] {
                identities.append(identity)
            }
        }
        return identities
    }

    /// Removes the head after sending or skipping it. A recoverable send
    /// failure leaves the head and following effects queued for replay.
    private func transportEffectCompleted(_ queuedEffect: RuntimeQueuedTransportEffect, delivered: Bool) {
        pendingOutboundEffects.removeFirst()
        if queuedEffect.isPublication { outboundQueued -= 1 }
        switch queuedEffect {
        case .publish:
            break
        case let .typedIoPublication(_, token: typedToken):
            if typedIoState.completeTransportPublication(typedToken) {
                flushPendingIo(at: typedToken.slot, nowMS: monotonicNowMS())
            }
        case let .presencePublication(_, token, completesBatch):
            if completesBatch, let index = localPresence.firstIndex(where: { $0.pendingBatch == token }) {
                localPresence[index].pendingBatch = nil
            }
        case let .externalRouteActivated(transition):
            if delivered { transportExternalRoutes.append(transition) }
        case let .externalRouteDeactivated(transition):
            if delivered, let index = transportExternalRoutes.firstIndex(of: transition) {
                transportExternalRoutes.remove(at: index)
            }
        }
        if presenceRefreshDeferred, state == .running, remainingOutboundCapacity > 0 {
            publishDuePresence(nowMS: presenceClock.nowMS())
        }
        flushOfflineOperations(nowMS: monotonicNowMS())
    }

    private func installOutboundPump() {
        let outboundPipe = AsyncStream<RuntimeTransportEffectBatch>.makeStream(
            bufferingPolicy: .bufferingOldest(definition.capacities.dispatch)
        )
        outboundContinuation = outboundPipe.continuation
        let epoch = transportEpoch
        outboundTask = Task { [weak self, stream = outboundPipe.stream] in
            for await batch in stream {
                for queuedEffect in batch.effects {
                    guard !Task.isCancelled,
                          await self?.sendOutboundEffect(queuedEffect, epoch: epoch) == true else { return }
                }
            }
        }
    }

    private func sendOutboundEffect(_ effect: RuntimeQueuedTransportEffect, epoch: UInt64) async -> Bool {
        guard !Task.isCancelled else { return false }
        if case let .presencePublication(_, token, _) = effect,
           state != .running || token.transportEpoch != transportEpoch
            || !localPresence.contains(where: { $0.pendingBatch == token }) {
            transportEffectCompleted(effect, delivered: false)
            return true
        }
        do {
            try await transport.perform(effect.transportEffect(namespace: definition.namespace, profile: wireProfile))
            transportEffectCompleted(effect, delivered: true)
            return true
        } catch {
            if state == .stopping {
                transportEffectCompleted(effect, delivered: false)
                emitTransportFailure(error)
                return true
            }
            if epoch == transportEpoch, !Task.isCancelled {
                let failure = RuntimeTransportFailure(code: .brokerUnavailable, detail: runtimeErrorDetail(error))
                // Recovery may need to join this pump. Report the failure
                // from a separate task so this send can return first.
                Task { [weak self] in await self?.outboundPumpFailed(failure, epoch: epoch) }
            }
            return false
        }
    }

    private func outboundPumpFailed(_ failure: RuntimeTransportFailure, epoch: UInt64) async {
        guard epoch == transportEpoch else { return }
        await transportFailed(failure)
    }

    private func finishOutboundPump(cancel: Bool = false) {
        outboundContinuation?.finish()
        outboundContinuation = nil
        if cancel { outboundTask?.cancel() }
    }

    private func joinOutboundPump(epoch: UInt64) async {
        await outboundTask?.value
        guard epoch == transportEpoch else { return }
        outboundTask = nil
    }

    func receive(_ frame: RuntimeInboundFrame) -> RuntimeReceipt {
        guard state == .running else {
            return .rejected(.notRunning(state))
        }
        // There is no separate holding queue here: `processInbound` is
        // synchronous, so the only real bound on outstanding inbound work is
        // the `AsyncStream` feeding `receiveTransport(_:epoch:)`
        // (`.bufferingOldest(definition.capacities.ingress)`) together with
        // `RuntimeOverflowGate`; saturation there is reported by
        // `ingressOverflow()`. A frame reaching this method has already
        // cleared that bound and is processed immediately.
        return processInbound(frame)
    }

    func publish(_ operation: RuntimeOperation, nowMS: UInt32, duringModuleShutdown: Bool = false) -> RuntimeReceipt {
        if operation.capability == .channel, operation.operationName == nil {
            return rejectRequest(operation, .invalidOperationName)
        }
        if let operationName = operation.operationName,
           (operation.capability != .call && operation.capability != .channel && operation.capability != .associate)
            || !RuntimeOperationValidation.isValidCallOperation(operationName) {
            return rejectRequest(operation, .invalidOperationName)
        }
        guard !operation.payload.isEmpty else {
            return rejectRequest(operation, .malformedPayload)
        }
        if presencePolicy == .enabled, operation.capability == .advertise,
           let rejection = genericAdvertisementRejection(operation) {
            return .rejected(rejection)
        }
        let withdrawals = managedWithdrawalIDs(operation)
        if state == .reconnecting {
            guard operation.capability.isOneWay, operation.correlationID == nil, withdrawals.isEmpty else {
                return rejectRequest(operation, .notRunning(state))
            }
            guard offlineOperations.count < definition.capacities.dispatch else {
                diagnosticsSnapshotValue.dispatchSaturation += 1
                emitAdmission(
                    .dispatch,
                    capacity: definition.capacities.dispatch,
                    detail: "offline dispatch queue is full"
                )
                return rejectRequest(operation, .capacityExceeded)
            }
            offlineOperations.append(operation)
            eventContinuation.yield(.transition(.accepted))
            return .accepted
        }
        guard admitsLocalWork(duringModuleShutdown: duringModuleShutdown) else {
            return rejectRequest(operation, .notRunning(state))
        }
        guard remainingOutboundCapacity > 0 else {
            diagnosticsSnapshotValue.dispatchSaturation += 1
            emitAdmission(
                .dispatch,
                capacity: definition.capacities.dispatch,
                detail: "outbound dispatch queue is full"
            )
            return rejectRequest(operation, .capacityExceeded)
        }
        let maximumActionCount = operation.capability == .associate
            ? min(definition.capacities.dispatch, remainingOutboundCapacity + 1)
            : remainingOutboundCapacity
        let processorNowMS = presencePolicy == .enabled && operation.capability == .advertise
            ? UInt32(truncatingIfNeeded: presenceClock.nowMS())
            : nowMS
        let outcome = processOutboundOperation(
            operation,
            nowMS: processorNowMS,
            maximumActionCount: maximumActionCount
        ) {
            if !withdrawals.isEmpty {
                localPresence.removeAll {
                    $0.sourceID == operation.sourceID && withdrawals.contains($0.objectID)
                }
            }
            dispatchActions(nowMS: nowMS)
        }
        let receipt = receipt(for: outcome)
        recordRequestReceipt(operation, receipt: receipt)
        eventContinuation.yield(.transition(receipt))
        if case .accepted = receipt {
            recordLocalPresence(operation)
        }
        return receipt
    }

    private func admitsLocalWork(duringModuleShutdown: Bool) -> Bool {
        state == .running || (duringModuleShutdown && state == .stopping && outboundContinuation != nil)
    }

    private func genericAdvertisementRejection(_ operation: RuntimeOperation) -> RuntimeRejection? {
        let codec = WireCodec(profile: wireProfile)
        return operation.payload.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return .malformedPayload }
            let reader = codec.reader(bytes: base, length: buffer.count)
            guard reader.readField("leaseMs") == nil, reader.readField("ownerEpoch") == nil else {
                return .malformedPayload
            }
            guard operation.sourceID == definition.sourceID else { return nil }
            let objectID = advertisedObjectID(in: reader, codec: codec) ?? operation.sourceID
            return localPresence.contains(where: {
                $0.sourceID == operation.sourceID && $0.objectID == objectID
            }) ? .protocol(.duplicate) : nil
        }
    }

    private func managedWithdrawalIDs(_ operation: RuntimeOperation) -> Set<UUID16> {
        guard operation.capability == .deadvertise, operation.sourceID == definition.sourceID,
              !localPresence.isEmpty else { return [] }
        return operation.payload.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return [] }
            let reader = WireCodec(profile: wireProfile).reader(bytes: base, length: buffer.count)
            var ids: Set<UUID16> = []
            do {
                try reader.readIdentifierElements("objectIds") { id in
                    if let id, localPresence.contains(where: {
                        $0.sourceID == operation.sourceID && $0.objectID == id
                    }) { ids.insert(id) }
                }
            } catch {
                // The processor supplies the structured rejection for invalid wire input.
                return []
            }
            return ids
        }
    }

    private func rejectRequest(
        _ operation: RuntimeOperation,
        _ rejection: RuntimeRejection
    ) -> RuntimeReceipt {
        recordRequestRejected(operation, rejection: rejection)
        return .rejected(rejection)
    }

    private func isRequestCapability(_ capability: ProtocolCapability) -> Bool {
        switch capability {
        case .discover, .query, .update, .call: return true
        default: return false
        }
    }

    private func isResponseCapability(_ capability: ProtocolCapability) -> Bool {
        switch capability {
        case .resolve, .retrieve, .complete, .returnEvent: return true
        default: return false
        }
    }

    private func recordRequestRejected(_ operation: RuntimeOperation, rejection: RuntimeRejection) {
        guard isRequestCapability(operation.capability), let correlationID = operation.correlationID else { return }
        diagnosticsSnapshotValue.rejectedRequests &+= 1
        emit(RuntimeDiagnostic(
            kind: .requestRejected,
            detail: "request rejected",
            sequence: 0,
            timestampMS: 0,
            observation: .request(RuntimeRequestObservation(
                capability: operation.capability,
                correlationID: correlationID,
                outcome: .rejected,
                rejection: rejection
            ))
        ))
    }

    private func recordRequestReceipt(_ operation: RuntimeOperation, receipt: RuntimeReceipt) {
        guard isRequestCapability(operation.capability), let correlationID = operation.correlationID else { return }
        switch receipt {
        case .accepted:
            pendingRequestCapabilities[correlationID] = operation.capability
            diagnosticsSnapshotValue.acceptedRequests &+= 1
            diagnosticsSnapshotValue.pendingRequests = processor.state.pendingCorrelations
            emit(RuntimeDiagnostic(
                kind: .requestAccepted,
                detail: "request accepted",
                sequence: 0,
                timestampMS: 0,
                observation: .request(RuntimeRequestObservation(
                    capability: operation.capability,
                    correlationID: correlationID,
                    outcome: .accepted
                ))
            ))
        case .rejected(let rejection):
            recordRequestRejected(operation, rejection: rejection)
        case .ignored:
            break
        }
    }

    private func recordInboundResponse(_ delivery: BorrowedProtocolDelivery) {
        let capability = delivery.routingKey.capability
        guard isResponseCapability(capability), let correlationID = delivery.routingKey.correlationID else { return }
        recordResponseReceived(capability, correlationID: correlationID)
    }

    private func recordResponseReceived(_ capability: ProtocolCapability, correlationID: UUID16) {
        diagnosticsSnapshotValue.responsesReceived &+= 1
        if !processorHasPending(correlationID) {
            pendingRequestCapabilities.removeValue(forKey: correlationID)
        }
        diagnosticsSnapshotValue.pendingRequests = processor.state.pendingCorrelations
        emit(RuntimeDiagnostic(
            kind: .responseReceived,
            detail: "correlated response received",
            sequence: 0,
            timestampMS: 0,
            observation: .request(RuntimeRequestObservation(
                capability: capability,
                correlationID: correlationID,
                outcome: .responseReceived
            ))
        ))
    }

    private func processorHasPending(_ correlationID: UUID16) -> Bool {
        pendingCorrelationIDs().contains(correlationID)
    }

    private func recordLocalPresence(_ operation: RuntimeOperation) {
        guard operation.capability == .advertise || operation.capability == .deadvertise else { return }
        let evidence: RuntimePresenceEvidence = operation.capability == .advertise
            ? .localAdvertisement
            : .localDeadvertisement
        recordPresence(
            capability: operation.capability,
            sourceID: operation.sourceID,
            payload: operation.payload,
            evidence: evidence
        )
    }

    private func recordInboundPresence(
        capability: ProtocolCapability,
        sourceID: UUID16,
        payload: [UInt8]
    ) {
        let evidence: RuntimePresenceEvidence = capability == .advertise
            ? .peerAdvertisement
            : .peerDeadvertisement
        recordPresence(
            capability: capability,
            sourceID: sourceID,
            payload: payload,
            evidence: evidence
        )
    }

    private func recordPresence(
        capability: ProtocolCapability,
        sourceID: UUID16,
        payload: [UInt8],
        evidence: RuntimePresenceEvidence
    ) {
        guard capability == .advertise || capability == .deadvertise else { return }
        let processorState = processor.state
        let objectID = capability == .advertise ? advertisedObjectID(in: payload) : nil
        let observation = RuntimePresenceObservation(
            sourceID: sourceID,
            objectID: objectID,
            evidence: evidence,
            activeObjects: processorState.activeObjects,
            generation: processorState.generation
        )
        diagnosticsSnapshotValue.activeObjects = processorState.activeObjects
        diagnosticsSnapshotValue.presenceGeneration = processorState.generation
        diagnosticsSnapshotValue.presenceChanges &+= 1
        diagnosticsSnapshotValue.lastPresence = observation
        guard evidence == .peerAdvertisement || evidence == .peerDeadvertisement else { return }
        diagnosticsSnapshotValue.presenceUncertain = false
        emit(RuntimeDiagnostic(
            kind: .presenceChanged,
            detail: "object presence changed",
            sequence: 0,
            timestampMS: 0,
            observation: .presence(observation)
        ))
    }

    private func advertisedObjectID(in payload: [UInt8]) -> UUID16? {
        let codec = WireCodec(profile: wireProfile)
        return payload.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return advertisedObjectID(in: codec.reader(bytes: base, length: buffer.count), codec: codec)
        }
    }

    private func advertisedObjectID(in reader: WireReader, codec: WireCodec) -> UUID16? {
        guard let object = reader.readField("object") else { return nil }
        return object.withBytes { objectPointer, objectLength in
            let objectReader = codec.reader(bytes: objectPointer.assumingMemoryBound(to: UInt8.self), length: objectLength)
            return objectReader.readUUID("objectId")
        }
    }

    private func flushOfflineOperations(nowMS: UInt32) {
        guard state == .running, !offlineOperations.isEmpty, !flushingOfflineOperations else { return }
        flushingOfflineOperations = true
        defer { flushingOfflineOperations = false }
        while let operation = offlineOperations.first {
            let receipt = publish(operation, nowMS: nowMS)
            switch receipt {
            case .accepted:
                offlineOperations.removeFirst()
            case .rejected(.capacityExceeded):
                return
            case let .rejected(rejection):
                offlineOperations.removeFirst()
                emit(.init(kind: .malformedFrame, detail: "offline operation dropped during replay: \(rejection)"))
            case .ignored:
                offlineOperations.removeFirst()
            }
        }
    }

    private func processInbound(_ frame: RuntimeInboundFrame) -> RuntimeReceipt {
        let outcome: ProtocolProcessOutcome
        var parseFailure: String?
        var inboundPresence: (ProtocolCapability, UUID16, [UInt8])?
        switch frame {
        case .profile(var topic, let payload, let nowMS):
            guard !topic.isEmpty else { return .rejected(.malformedFrame(.malformedFrame)) }
            guard !payload.isEmpty else { return .rejected(.malformedPayload) }
            outcome = topic.withUTF8 { topicBuffer in
                guard let topicBase = topicBuffer.baseAddress else {
                    parseFailure = "topic is empty"
                    return .rejected(.malformedFrame)
                }
                let topicView = TopicView(topicBytes: topicBase, length: topicBuffer.count)
                do throws(WireDecodeError) {
                    try topicView.validate(
                        maximumTopicLength: definition.capacities.protocolMaximumTopicBytes,
                        profile: wireProfile
                    )
                } catch {
                    parseFailure = runtimeErrorDetail(error)
                    return .rejected(.malformedFrame)
                }
                return payload.withUnsafeBufferPointer { payloadBuffer in
                    guard let payloadBase = payloadBuffer.baseAddress else {
                        parseFailure = "payload is empty"
                        return .rejected(.malformedPayload)
                    }
                    do throws(ProtocolError) {
                        let borrowed = try BorrowedProtocolFrame(
                            topic: topicView,
                            payload: ByteSlice(bytes: payloadBase, length: payloadBuffer.count),
                            maximumTopicLength: definition.capacities.protocolMaximumTopicBytes
                        )
                        let capability = borrowed.routingKey.capability
                        let sourceID = borrowed.routingKey.sourceID
                        actionSink.removeAll()
                        let maximumActionCount = capability == .associate
                            ? min(definition.capacities.dispatch, remainingOutboundCapacity + 1)
                            : remainingOutboundCapacity
                        actionSink.prepare(maximumActionCount: maximumActionCount)
                        let processorNowMS = presencePolicy == .enabled && capability == .advertise
                            ? UInt32(truncatingIfNeeded: presenceClock.nowMS())
                            : nowMS
                        let outcome = processor.processInbound(
                            .profile(borrowed),
                            nowMS: processorNowMS,
                            classifier: TransportRouteClassifier(transport: transport),
                            maximumTopicLength: definition.capacities.protocolMaximumTopicBytes,
                            sink: &actionSink
                        )
                        if case .accepted = outcome {
                            if (capability == .advertise || capability == .deadvertise),
                               hasDelivery(for: capability) {
                                inboundPresence = (capability, sourceID, payload)
                            }
                            dispatchActions(nowMS: nowMS)
                        }
                        return outcome
                    } catch {
                        parseFailure = runtimeErrorDetail(error)
                        return .rejected(.malformedFrame)
                    }
                }
            }
        case .externalIo(var route, let payload, let nowMS):
            guard !route.isEmpty,
                  route.utf8.count <= WireBufferConfig.maxTopicLength,
                  payload.count <= WireBufferConfig.maxPayloadSize else {
                return .rejected(.malformedPayload)
            }
            outcome = route.withUTF8 { routeBuffer in
                guard let routeBase = routeBuffer.baseAddress else {
                    return .rejected(.malformedPayload)
                }
                return payload.withUnsafeBufferPointer { payloadBuffer in
                    let payloadSlice = payloadBuffer.baseAddress.map {
                        ByteSlice(bytes: $0, length: payloadBuffer.count)
                    } ?? .empty
                    let routeSlice = ByteSlice(bytes: routeBase, length: routeBuffer.count)
                    actionSink.removeAll()
                    actionSink.prepare(maximumActionCount: definition.capacities.dispatch)
                    let outcome = processor.processInbound(
                        .externalIo(route: routeSlice, payload: payloadSlice),
                        nowMS: nowMS,
                        classifier: TransportRouteClassifier(transport: transport),
                        sink: &actionSink
                    )
                    if case .accepted = outcome {
                        dispatchActions(nowMS: nowMS)
                    }
                    return outcome
                }
            }
        }
        if let parseFailure {
            diagnosticsSnapshotValue.malformedFrames += 1
            emit(.init(kind: .malformedFrame, detail: parseFailure))
        }
        if case .accepted = outcome, let inboundPresence {
            recordInboundPresence(
                capability: inboundPresence.0,
                sourceID: inboundPresence.1,
                payload: inboundPresence.2
            )
        }
        let receipt = receipt(for: outcome)
        eventContinuation.yield(.transition(receipt))
        guard case .accepted = receipt else { return receipt }
        return receipt
    }

    private func hasDelivery(for capability: ProtocolCapability) -> Bool {
        (0..<actionSink.count).contains { index in
            guard case let .deliver(delivery)? = actionSink[index] else { return false }
            return delivery.routingKey.capability == capability
        }
    }

    private func dispatchActions(
        nowMS: UInt32,
        presence: (token: RuntimePresencePublicationToken, isAnnouncement: Bool)? = nil
    ) {
        guard actionSink.count <= definition.capacities.dispatch else {
            emitAdmission(
                .dispatch,
                capacity: definition.capacities.dispatch,
                detail: "dispatch queue is full"
            )
            actionSink.removeAll()
            return
        }
        var effects: [RuntimeQueuedTransportEffect] = []
        effects.reserveCapacity(actionSink.count)
        var changedSourceIDs: Set<ObjectID> = []
        var changedActorIDs: Set<ObjectID> = []
        for index in 0..<actionSink.count {
            guard let borrowed = actionSink[index] else { continue }
            let action = borrowed.owned()
            recordConformanceAction(action)
            switch borrowed {
            case .deliver(let delivery):
                recordInboundResponse(delivery)
                emitRegisteredEvents(for: delivery, owned: action, nowMS: nowMS)
                dispatchToHandler(action, operation: operationName(for: delivery))
                dispatchIoActorIfRegistered(action, nowMS: nowMS)
            case .associationChanged(let transition):
                // A Deadvertise that removes an association endpoint reports
                // the released slots against the Deadvertise frame. That frame
                // already reached handlers and event streams as a delivery, so
                // only a wire Associate frame dispatches again here.
                if transition.delivery.routingKey.capability == .associate {
                    recordInboundResponse(transition.delivery)
                    emitRegisteredEvents(for: transition.delivery, owned: action, nowMS: nowMS)
                    dispatchToHandler(action, operation: operationName(for: transition.delivery))
                }
                changedSourceIDs.insert(ObjectID(uuid: transition.sourceID))
                changedActorIDs.insert(ObjectID(uuid: transition.actorID))
            case .publish(let publication):
                if publication.isApplicationDelivery,
                   presence?.isAnnouncement != false,
                   let delivery = syntheticDelivery(for: publication) {
                    emitRegisteredEvents(for: delivery, owned: action, nowMS: nowMS)
                }
                if case .publish(let ownedPublication) = action {
                    if let presence {
                        effects.append(.presencePublication(
                            ownedPublication, token: presence.token, completesBatch: index == actionSink.count - 1
                        ))
                    } else if ownedPublication.routingKey.capability == .ioValue,
                       let token = pendingTypedIoToken {
                        effects.append(.typedIoPublication(ownedPublication, token: token))
                        pendingTypedIoToken = nil
                    } else {
                        effects.append(.publish(ownedPublication))
                    }
                }
            case .externalRouteActivated(let transition):
                effects.append(.externalRouteActivated(transition.owned()))
            case .externalRouteDeactivated(let transition):
                effects.append(.externalRouteDeactivated(transition.owned()))
            }
        }
        actionSink.removeAll()
        enqueueTransportEffects(effects)
        notifyIoObservers(sourceIDs: changedSourceIDs, actorIDs: changedActorIDs)
    }

    func emitRegisteredEvents(for delivery: BorrowedProtocolDelivery, owned: OwnedProtocolAction, nowMS: UInt32) {
        let payload: [UInt8]
        switch owned {
        case .deliver(let value): payload = value.payload
        case .publish(let value): payload = value.payload
        case .associationChanged(let value): payload = value.delivery.payload
        case .externalRouteActivated, .externalRouteDeactivated: return
        }
        for registration in eventRegistrations {
            guard matches(registration.selector, delivery: delivery) else { continue }
            let value = RuntimeEventValue(
                family: eventFamily(for: delivery.routingKey.capability),
                context: RuntimeEventContext(
                    sourceID: delivery.routingKey.sourceID,
                    correlationID: delivery.routingKey.correlationID,
                    namespace: definition.namespace,
                    route: delivery.routeClassification,
                    channelIdentifier: channelIdentifier(for: delivery),
                    receiptTimeMS: nowMS,
                    provenance: owned.isPublication ? .local : .transport
                ),
                value: payload
            )
            let result = registration.continuation.yield(value)
            if case .dropped = result {
                diagnosticsSnapshotValue.dispatchSaturation += 1
                emitAdmission(
                    .applicationEvents,
                    outcome: .dropped,
                    capacity: definition.capacities.stream,
                    detail: "application event stream is full"
                )
                switch registration.policy {
                case .failAfterDrop, .fail:
                    failRuntime(
                        code: .capacityExceeded,
                        detail: "strict application event stream is full",
                        diagnostic: .capacityExceeded
                    )
                case .dropOldest, .dropNewest, .coalesceLatest:
                    break
                }
            }
        }
    }

    private func matches(_ selector: RuntimeEventSelector, delivery: BorrowedProtocolDelivery) -> Bool {
        switch selector {
        case let .family(family):
            return eventFamily(for: delivery.routingKey.capability) == family
        case let .advertise(objectType):
            guard delivery.routingKey.capability == .advertise else { return false }
            guard let objectType else { return true }
            guard case let .advertiseFilter(filter) = delivery.deliveryKey else { return false }
            return filter.utf8Equals(objectType)
        case let .channel(identifier):
            guard delivery.routingKey.capability == .channel,
                  case let .channel(channel) = delivery.deliveryKey else { return false }
            return channel.utf8Equals(identifier)
        case let .ioActor(actorID):
            guard case let .ioActor(value) = delivery.deliveryKey else { return false }
            return value == actorID
        case let .correlatedResponse(capability, correlationID):
            return delivery.routingKey.capability == capability && delivery.routingKey.correlationID == correlationID
        }
    }
    private func syntheticDelivery(for publication: BorrowedProtocolPublication) -> BorrowedProtocolDelivery? {
        let deliveryKey: BorrowedProtocolDeliveryKey
        let routeClassification: ProtocolRouteClassification
        switch publication.target {
        case .profile(let filter, _):
            routeClassification = .coaty
            switch publication.routingKey.capability {
            case .advertise: deliveryKey = filter.map { .advertiseFilter($0) } ?? .capability(.advertise)
            case .channel: deliveryKey = filter.map { .channel($0) } ?? .capability(.channel)
            default: deliveryKey = .capability(publication.routingKey.capability)
            }
        case .associationRoute(_, let kind):
            routeClassification = kind
            deliveryKey = .capability(publication.routingKey.capability)
        }
        return BorrowedProtocolDelivery(
            routingKey: publication.routingKey,
            deliveryKey: deliveryKey,
            routeClassification: routeClassification,
            topic: nil,
            payload: publication.payload
        )
    }
    private func channelIdentifier(for delivery: BorrowedProtocolDelivery) -> String? {
        guard delivery.routingKey.capability == .channel,
              case let .channel(identifier) = delivery.deliveryKey else { return nil }
        return identifier.asString()
    }
    private func eventFamily(for capability: ProtocolCapability) -> RuntimeEventFamily {
        switch capability {
        case .advertise: return .advertise
        case .deadvertise: return .deadvertise
        case .channel: return .channel
        case .associate: return .associate
        case .ioValue: return .ioValue
        case .discover: return .discover
        case .resolve: return .resolve
        case .query: return .query
        case .retrieve: return .retrieve
        case .update: return .update
        case .complete: return .complete
        case .call: return .call
        case .returnEvent: return .returnEvent
        }
    }
    private func receiveTransport(_ frame: RuntimeInboundFrame, epoch: UInt64) {
        guard epoch == transportEpoch else {
            // A frame from a superseded transport epoch is routine during a
            // reconnect, not capacity exhaustion -- keep it out of the
            // capacity/saturation signal.
            emit(.init(kind: .staleTransportFrame, detail: "stale transport frame ignored"))
            return
        }
        _ = receive(frame)
    }

    private func operationName(for delivery: BorrowedProtocolDelivery) -> String? {
        guard delivery.routingKey.capability == .call, let topic = delivery.topic else { return nil }
        return topic.withBytes { pointer, length in
            let view = TopicView(topicBytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
            guard let filter = view.eventTypeFilter else { return nil }
            return filter.withBytes { filterPointer, filterLength in
                String(decoding: UnsafeBufferPointer(
                    start: filterPointer.assumingMemoryBound(to: UInt8.self),
                    count: filterLength
                ), as: UTF8.self)
            }
        }
    }

    private func enqueueTransportEffects(_ effects: [RuntimeQueuedTransportEffect]) {
        guard !effects.isEmpty else { return }
        guard effects.count <= remainingOutboundCapacity,
              case .enqueued? = outboundContinuation?.yield(RuntimeTransportEffectBatch(effects: effects)) else {
            // A preflighted action batch fits both the retained queue and the
            // pump. Fail if a caller violates that admission contract.
            diagnosticsSnapshotValue.dispatchSaturation += 1
            emitAdmission(
                .dispatch,
                capacity: definition.capacities.dispatch,
                detail: "outbound dispatch queue is full"
            )
            failRuntime(
                code: .capacityExceeded,
                detail: "outbound dispatch queue is full",
                diagnostic: .capacityExceeded
            )
            return
        }
        pendingOutboundEffects.append(contentsOf: effects)
        outboundQueued += effects.count(where: \.isPublication)
    }

    /// Re-enqueues effects that were queued-but-unsent when the transport
    /// last failed, in publication order, after a successful reconnect.
    /// Called before `flushOfflineOperations(nowMS:)` so already-accepted
    /// work is replayed ahead of operations accepted while reconnecting.
    ///
    /// Request publications are never replayed. Reconnect discards the
    /// pending-correlation ledger, so replaying a request would either create
    /// an untracked command or make a late response ambiguous. One-way
    /// publications remain safe to replay. Managed presence re-announces at
    /// its next phase in the new epoch.
    private func replayQueuedOutboundEffects() {
        guard !pendingOutboundEffects.isEmpty else { return }
        let effects = pendingOutboundEffects.filter { effect in
            switch effect {
            case let .publish(publication): return publication.routingKey.capability.isOneWay
            case .presencePublication: return false
            case .typedIoPublication, .externalRouteActivated, .externalRouteDeactivated: return true
            }
        }
        pendingOutboundEffects.removeAll(keepingCapacity: true)
        outboundQueued = 0
        enqueueTransportEffects(effects)
    }

    private func cancelIngressPump() {
        transportIngressRelay.finish()
        transportIngressContinuation?.finish()
        transportIngressContinuation = nil
        transportIngressTask?.cancel()
        transportIngressTask = nil
    }

    private func cancelAndDrainIngressPump() async {
        let task = transportIngressTask
        cancelIngressPump()
        await task?.value
    }

    private func emitTransportFailure(_ error: any Error) {
        let detail = runtimeErrorDetail(error)
        emit(RuntimeDiagnostic(
            kind: .transportFailed,
            detail: detail,
            sequence: 0,
            timestampMS: 0,
            observation: .transportFailure(RuntimeTransportObservation(
                code: .brokerUnavailable,
                detail: detail
            ))
        ))
    }

    private func transportFailed(_ failure: RuntimeTransportFailure) async {
        diagnosticsSnapshotValue.transportFailures += 1
        guard state == .running || state == .reconnecting || state == .starting else { return }
        emit(RuntimeDiagnostic(
            kind: .transportFailed,
            detail: failure.detail,
            sequence: 0,
            timestampMS: 0,
            observation: .transportFailure(RuntimeTransportObservation(
                code: failure.code,
                detail: failure.detail
            ))
        ))
        // Established-connection loss is recoverable transport state, not a
        // terminal runtime failure.  Leave the executor in an explicit
        // reconnecting state so the caller can restore the network path and
        // invoke `reconnect()` without losing the immutable definition.
        guard state == .running else {
            if state == .reconnecting { softRecoveryConsumed = false }
            return
        }
        transition(to: .reconnecting)
        softRecoveryConsumed = false
        transportEpoch &+= 1
        let epoch = transportEpoch
        suspendTransport(.transportFailure)
        let alreadyRecovered = recoveryArrivedBeforeFailure
        recoveryArrivedBeforeFailure = false
        await stopPresenceTimer(epoch: epoch)
        guard alreadyRecovered, reconnectAttemptIsCurrent(epoch) else { return }
        await transportRecovered()
    }

    func failRuntime(
        code: AxolotyError.RuntimeErrorCode,
        detail: String,
        diagnostic: RuntimeDiagnostic.Kind,
        observation: RuntimeObservation? = nil
    ) {
        if terminalFailureValue == nil {
            terminalFailureValue = (code, detail)
        }
        emit(RuntimeDiagnostic(
            kind: diagnostic,
            detail: detail,
            sequence: 0,
            timestampMS: 0,
            observation: observation
        ))
        guard state != .stopping, state != .stopped, state != .closed else { return }
        transition(to: .failed)
        signalTermination()
        transportEpoch &+= 1
        transportCallbackEpoch = nil
        presenceTask?.cancel()
        cancelIngressPump()
        // Teardown joins the pump after the current actor turn has enqueued
        // any effects from the accepted batch that caused the failure.
        guard !failureTeardownScheduled else { return }
        failureTeardownScheduled = true
        Task { [weak self] in
            await self?.stop()
        }
    }

    func emitAdmission(
        _ resource: RuntimeAdmissionResource,
        outcome: RuntimeAdmissionOutcome = .rejected,
        capacity: Int,
        detail: String
    ) {
        emit(RuntimeDiagnostic(
            kind: .capacityExceeded,
            detail: detail,
            sequence: 0,
            timestampMS: 0,
            observation: .admission(RuntimeAdmissionObservation(
                resource: resource,
                outcome: outcome,
                capacity: capacity
            ))
        ))
    }

    func emit(_ diagnostic: RuntimeDiagnostic) {
        diagnosticSequence &+= 1
        let owned = RuntimeDiagnostic(
            kind: diagnostic.kind,
            detail: diagnostic.detail,
            sequence: diagnosticSequence,
            timestampMS: monotonicNowMS(),
            observation: diagnostic.observation
        )
        diagnosticsSnapshotValue.diagnosticSequence = diagnosticSequence
        diagnosticsSnapshotValue.diagnosticsEmitted &+= 1
        let result = diagnosticContinuation.yield(owned)
        switch result {
        case .enqueued:
            break
        case .dropped:
            diagnosticsSnapshotValue.diagnosticsDropped &+= 1
        case .terminated:
            break
        @unknown default:
            break
        }
    }

    /// Appends one copied action for ``conformanceObservation()``, bounded by
    /// `definition.capacities.dispatch` so a production runtime that never
    /// drains the conformance SPI cannot grow this buffer without bound.
    private func recordConformanceAction(_ action: OwnedProtocolAction) {
        if conformanceActions.count >= definition.capacities.dispatch {
            conformanceActions.removeFirst()
        }
        conformanceActions.append(action)
    }

}
