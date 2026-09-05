// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyObjectModel
import AxolotyWire

struct RuntimeTypedIoPublicationToken: Sendable, Equatable {
    let slot: Int
    let generation: UInt32
    let executionGeneration: UInt64
    let attempt: UInt64

    init(slot: Int, generation: UInt32, executionGeneration: UInt64, attempt: UInt64) {
        self.slot = slot
        self.generation = generation
        self.executionGeneration = executionGeneration
        self.attempt = attempt
    }
}

/// Executor-owned mutable state for registered typed IO endpoints.
///
/// The value contains publication timing, pending values, association
/// observers, and flush handles. The protocol processor remains the source of
/// truth for association state; the executor remains responsible for transport
/// admission and handler supervision.
struct RuntimeTypedIoState: Sendable {
    struct Endpoint: Sendable {
        let registration: RuntimeIoEndpointRegistration
        let generation: UInt32
        var machine = IoPublicationStateMachine()
        var pending: [UInt8]?
        var inFlight = false
        var nextAttempt: UInt64 = 1
        var activeAttempt: UInt64?
    }

    struct Observer: Sendable {
        let sourceID: ObjectID?
        let actorID: ObjectID?
        let continuation: AsyncStream<IoAssociationState>.Continuation
        var lastGeneration: UInt32
        let policy: RuntimeBufferingPolicy
    }

    typealias PublicationToken = RuntimeTypedIoPublicationToken

    struct PublicationCompletion: Sendable {
        let receipt: IoPublicationReceipt
        let flushRequest: FlushRequest?
    }

    enum PublicationPlan: Sendable {
        case publish(token: PublicationToken, sourceID: ObjectID, payload: [UInt8])
        case queueLatest(token: PublicationToken, payload: [UInt8])
        case receipt(IoPublicationReceipt)
    }

    struct FlushRequest: Sendable, Equatable {
        let slot: Int
        let token: PublicationToken
        let delayMS: UInt32
    }

    var endpoints: [Endpoint]
    var observers: [UInt64: Observer] = [:]
    var nextObserverID: UInt64 = 1
    var flushTasks: [Int: Task<Void, Never>] = [:]
    private var executionGeneration: UInt64 = 0
    private let registryID: ObjectID
    private let observerCapacity: Int
    private let pendingCapacity: Int

    init(registrations: RuntimeRegistrations) {
        self.registryID = registrations.registryID
        self.observerCapacity = registrations.capacities.ioObservers
        self.pendingCapacity = registrations.capacities.ioPendingLatest
        self.endpoints = registrations.ioEndpointRegistrations.enumerated().map { index, registration in
            Endpoint(
                registration: registration,
                generation: registrations.endpointGenerations[index],
                pending: nil
            )
        }
    }

    var hasEndpoints: Bool { !endpoints.isEmpty }
    func isSource(at slot: Int) -> Bool {
        endpoint(at: slot)?.registration.role == .source
    }
    var endpointRegistrations: [RuntimeIoEndpointRegistration] {
        endpoints.map(\.registration)
    }

    func endpoint(at slot: Int) -> Endpoint? {
        guard endpoints.indices.contains(slot) else { return nil }
        return endpoints[slot]
    }

    func sourceSlot<Value: IoEndpointValue>(_ source: IoSource<Value>) -> Int? {
        let slot = Int(source.runtimeSlot)
        guard endpoints.indices.contains(slot) else { return nil }
        let endpoint = endpoints[slot]
        guard endpoint.registration.role == .source,
              source.matches(
                  registryID: registryID,
                  slot: source.runtimeSlot,
                  generation: endpoint.generation,
                  id: endpoint.registration.id,
                  representation: endpoint.registration.representation
              ) else { return nil }
        return slot
    }

    func actorSlot<Value: IoEndpointValue>(_ actor: IoActor<Value>) -> Int? {
        let slot = Int(actor.runtimeSlot)
        guard endpoints.indices.contains(slot) else { return nil }
        let endpoint = endpoints[slot]
        guard endpoint.registration.role == .actor,
              actor.matches(
                  registryID: registryID,
                  slot: actor.runtimeSlot,
                  generation: endpoint.generation,
                  id: endpoint.registration.id,
                  representation: endpoint.registration.representation
              ) else { return nil }
        return slot
    }

    func actorSlot(forID id: ObjectID) -> Int? {
        endpoints.firstIndex { $0.registration.role == .actor && $0.registration.id == id }
    }

    /// Prepares admission at the supplied time. This overload keeps timing
    /// explicit for the executor's synchronous prepare/complete transaction.
    mutating func preparePublication<Value: IoEndpointValue>(
        _ payload: [UInt8],
        representation: IoValueRepresentation,
        from source: IoSource<Value>,
        association: IoAssociationState,
        nowMS: UInt32,
        dispatchAvailable: Bool
    ) -> PublicationPlan {
        guard let slot = sourceSlot(source), let endpoint = endpoint(at: slot) else {
            return .receipt(.rejected(.invalidEndpoint))
        }
        guard endpoint.registration.representation == representation else {
            return .receipt(.rejected(.malformedPayload))
        }
        guard association.hasAssociations else {
            return .receipt(.notAssociated)
        }
        let token = PublicationToken(
            slot: slot,
            generation: endpoint.generation,
            executionGeneration: executionGeneration,
            attempt: endpoints[slot].nextAttempt
        )
        let decision = endpoint.machine.decision(
            policy: endpoint.registration.publication,
            association: association,
            nowMS: nowMS
        )
        switch decision {
        case .notAssociated: return .receipt(.notAssociated)
        case .throttled: return .receipt(.throttled)
        case .replaceLatest:
            guard canQueueLatest(at: slot) else { return .receipt(.rejected(.capacityExceeded)) }
            return .queueLatest(token: token, payload: payload)
        case .emitCurrent:
            guard !endpoint.inFlight, dispatchAvailable else {
                if case .latest = endpoint.registration.publication,
                   canQueueLatest(at: slot) {
                    return .queueLatest(token: token, payload: payload)
                }
                return .receipt(.rejected(.capacityExceeded))
            }
            endpoints[slot].nextAttempt &+= 1
            return .publish(token: token, sourceID: endpoint.registration.id, payload: payload)
        }
    }

    mutating func completePublication(
        _ plan: PublicationPlan,
        outcome: RuntimeReceipt?,
        nowMS: UInt32,
        association: IoAssociationState
    ) -> PublicationCompletion? {
        switch plan {
        case .receipt:
            return nil
        case let .queueLatest(token, payload):
            guard isCurrent(token) else { return nil }
            endpoints[token.slot].pending = payload
            return PublicationCompletion(
                receipt: .queuedLatest,
                flushRequest: makeFlushRequest(for: token, association: association)
            )
        case let .publish(token, _, payload):
            guard isCurrent(token) else { return nil }
            switch outcome {
            case .some(.accepted):
                endpoints[token.slot].machine.commitEmission(at: nowMS)
                endpoints[token.slot].inFlight = true
                endpoints[token.slot].activeAttempt = token.attempt
            case .some(.ignored):
                clear(at: token.slot)
            case .some(.rejected(.capacityExceeded)), .none:
                if case .some(.rejected(.capacityExceeded)) = outcome,
                   case .latest = endpoints[token.slot].registration.publication,
                   canQueueLatest(at: token.slot) {
                    endpoints[token.slot].pending = payload
                    return PublicationCompletion(
                        receipt: .queuedLatest,
                        flushRequest: makeFlushRequest(for: token, association: association)
                    )
                }
            case .some(.rejected):
                break
            }
            let receipt: IoPublicationReceipt
            switch outcome {
            case .some(.accepted): receipt = .published
            case .some(.ignored): receipt = .notAssociated
            case .some(.rejected(.capacityExceeded)): receipt = .rejected(.capacityExceeded)
            case let .some(.rejected(.protocol(code))): receipt = .rejected(code)
            case .some(.rejected), .none: receipt = .rejected(.malformedPayload)
            }
            return PublicationCompletion(receipt: receipt, flushRequest: nil)
        }
    }

    mutating func completePendingPublication(
        _ token: PublicationToken,
        outcome: RuntimeReceipt,
        nowMS: UInt32,
        association: IoAssociationState
    ) -> FlushRequest? {
        guard isCurrent(token), endpoints[token.slot].pending != nil else { return nil }
        switch outcome {
        case .accepted:
            endpoints[token.slot].pending = nil
            endpoints[token.slot].machine.commitEmission(at: nowMS)
            endpoints[token.slot].inFlight = true
            endpoints[token.slot].activeAttempt = token.attempt
        case .ignored:
            clear(at: token.slot)
        case .rejected(.capacityExceeded):
            return makeFlushRequest(for: token, association: association)
        case .rejected:
            break
        }
        return nil
    }

    mutating func preparePendingPublication(
        at slot: Int,
        association: IoAssociationState,
        nowMS: UInt32,
        dispatchAvailable: Bool
    ) -> PublicationPlan {
        guard endpoints.indices.contains(slot), let payload = endpoints[slot].pending else {
            return .receipt(.rejected(.capacityExceeded))
        }
        let endpoint = endpoints[slot]
        let token = PublicationToken(
            slot: slot,
            generation: endpoint.generation,
            executionGeneration: executionGeneration,
            attempt: endpoints[slot].nextAttempt
        )
        guard association.hasAssociations else { return .receipt(.notAssociated) }
        guard !endpoint.inFlight, dispatchAvailable else { return .receipt(.rejected(.capacityExceeded)) }
        switch endpoint.machine.decision(policy: endpoint.registration.publication, association: association, nowMS: nowMS) {
        case .emitCurrent:
            endpoints[slot].nextAttempt &+= 1
            return .publish(token: token, sourceID: endpoint.registration.id, payload: payload)
        case .replaceLatest:
            return .queueLatest(token: token, payload: payload)
        case .throttled:
            return .receipt(.throttled)
        case .notAssociated:
            return .receipt(.notAssociated)
        }
    }

    mutating func clearTransportState() {
        executionGeneration &+= 1
        for task in flushTasks.values { task.cancel() }
        flushTasks.removeAll(keepingCapacity: true)
        for index in endpoints.indices { clear(at: index) }
    }

    mutating func clearEndpoint(at slot: Int) {
        guard endpoints.indices.contains(slot) else { return }
        clear(at: slot)
    }

    func flushRequest(at slot: Int, association: IoAssociationState) -> FlushRequest? {
        guard endpoints.indices.contains(slot), endpoints[slot].pending != nil else { return nil }
        let token = PublicationToken(
            slot: slot,
            generation: endpoints[slot].generation,
            executionGeneration: executionGeneration,
            attempt: endpoints[slot].nextAttempt
        )
        return makeFlushRequest(for: token, association: association)
    }

    mutating func addObserver(
        sourceID: ObjectID?,
        actorID: ObjectID?,
        snapshot: IoAssociationState,
        buffering: RuntimeBufferingPolicy,
        continuation: AsyncStream<IoAssociationState>.Continuation
    ) throws(ProtocolError) -> (id: UInt64, snapshot: IoAssociationState) {
        guard observers.count < observerCapacity else { throw ProtocolError(.capacityExceeded) }
        let id = nextObserverID
        nextObserverID &+= 1
        observers[id] = Observer(
            sourceID: sourceID,
            actorID: actorID,
            continuation: continuation,
            lastGeneration: snapshot.generation,
            policy: buffering
        )
        return (id, snapshot)
    }

    mutating func removeObserver(_ id: UInt64) { observers.removeValue(forKey: id) }

    mutating func finishObservers() {
        for observer in observers.values { observer.continuation.finish() }
        observers.removeAll(keepingCapacity: true)
    }

    mutating func notifyObservers(
        sourceState: (ObjectID) -> IoAssociationState,
        actorState: (ObjectID) -> IoAssociationState,
        onStrictOverflow: (UInt64) -> Void,
        sourceIDs: Set<ObjectID>,
        actorIDs: Set<ObjectID>
    ) {
        for id in Array(observers.keys) {
            guard var observer = observers[id] else { continue }
            let state: IoAssociationState
            if let sourceID = observer.sourceID {
                guard sourceIDs.contains(sourceID) else { continue }
                state = sourceState(sourceID)
            } else if let actorID = observer.actorID {
                guard actorIDs.contains(actorID) else { continue }
                state = actorState(actorID)
            } else {
                continue
            }
            guard state.generation != observer.lastGeneration else { continue }
            observer.lastGeneration = state.generation
            observers[id] = observer
            let result = observer.continuation.yield(state)
            if case .dropped = result {
                switch observer.policy {
                case .failAfterDrop, .fail:
                    observer.continuation.finish()
                    observers.removeValue(forKey: id)
                    onStrictOverflow(id)
                case .dropOldest, .dropNewest, .coalesceLatest:
                    break
                }
            }
        }
    }

    mutating func installFlushTask(_ task: Task<Void, Never>, for request: FlushRequest) {
        flushTasks[request.slot] = task
    }

    mutating func takeFlushTask(for token: PublicationToken) -> Bool {
        guard isCurrent(token), flushTasks[token.slot] != nil else { return false }
        flushTasks.removeValue(forKey: token.slot)
        return true
    }

    mutating func completeTransportPublication(_ token: PublicationToken) -> Bool {
        guard isCurrent(token), endpoints[token.slot].activeAttempt == token.attempt else { return false }
        endpoints[token.slot].inFlight = false
        endpoints[token.slot].activeAttempt = nil
        return true
    }

    private func isCurrent(_ token: PublicationToken) -> Bool {
        endpoints.indices.contains(token.slot)
            && endpoints[token.slot].generation == token.generation
            && executionGeneration == token.executionGeneration
    }

    private func canQueueLatest(at slot: Int) -> Bool {
        if endpoints[slot].pending != nil { return true }
        return endpoints.reduce(into: 0) { count, endpoint in
            if endpoint.pending != nil { count += 1 }
        } < pendingCapacity
    }

    private mutating func clear(at slot: Int) {
        endpoints[slot].machine.clear()
        endpoints[slot].pending = nil
        endpoints[slot].inFlight = false
        endpoints[slot].activeAttempt = nil
    }

    private func makeFlushRequest(for token: PublicationToken, association: IoAssociationState) -> FlushRequest {
        let policyInterval: UInt32
        switch endpoints[token.slot].registration.publication {
        case .immediate: policyInterval = 0
        case .latest(let interval), .throttle(let interval): policyInterval = interval
        }
        return FlushRequest(
            slot: token.slot,
            token: token,
            delayMS: max(1, max(policyInterval, association.recommendedUpdateRateMS ?? 0))
        )
    }
}
