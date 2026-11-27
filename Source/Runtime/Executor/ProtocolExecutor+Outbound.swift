// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyWire

extension ProtocolExecutor {
    /// Emits one locally generated lifecycle publication through the bounded
    /// event registrations before it is handed to transport.
    func emitRegisteredEvents(for publication: OwnedProtocolPublication, nowMS: UInt32) {
        guard case .profile(let filter, _) = publication.target else { return }
        publication.payload.withUnsafeBufferPointer { payloadBuffer in
            guard let payloadBase = payloadBuffer.baseAddress else { return }
            let payload = ByteSlice(bytes: payloadBase, length: payloadBuffer.count)
            let deliver = { (filterBytes: ByteSlice?) in
                let key: BorrowedProtocolDeliveryKey
                switch publication.routingKey.capability {
                case .advertise:
                    key = filterBytes.map { .advertiseFilter($0) } ?? .capability(.advertise)
                case .channel:
                    key = filterBytes.map { .channel($0) } ?? .capability(.channel)
                default:
                    key = .capability(publication.routingKey.capability)
                }
                let delivery = BorrowedProtocolDelivery(
                    routingKey: publication.routingKey,
                    deliveryKey: key,
                    routeClassification: .coaty,
                    payload: payload
                )
                self.emitRegisteredEvents(for: delivery, owned: .publish(publication), nowMS: nowMS)
            }
            if let filter {
                filter.withUnsafeBufferPointer { buffer in
                    let bytes = buffer.baseAddress.map {
                        ByteSlice(bytes: $0, length: buffer.count)
                    }
                    deliver(bytes)
                }
            } else {
                deliver(nil)
            }
        }
    }

    /// Processes a lifecycle operation through the portable processor and
    /// waits for the resulting transport effects. Lifecycle sends
    /// must complete before startup/reconnect becomes ready or shutdown removes
    /// subscriptions, while ordinary publications continue through the
    /// bounded outbound pump.
    func publishLifecycle(
        _ operation: RuntimeOperation,
        nowMS: UInt32,
        emitApplicationEvents: Bool = true
    ) async throws(AxolotyError) {
        var effects: [RuntimeQueuedTransportEffect] = []
        let outcome = processOutboundOperation(
            operation,
            nowMS: nowMS,
            maximumActionCount: definition.capacities.dispatch
        ) {
            effects.reserveCapacity(actionSink.count)
            for index in 0..<actionSink.count {
                guard let action = actionSink[index] else { continue }
                switch action {
                case .publish(let publication):
                    effects.append(.publish(publication.owned()))
                case .externalRouteActivated(let transition):
                    effects.append(.externalRouteActivated(transition.owned()))
                case .externalRouteDeactivated(let transition):
                    effects.append(.externalRouteDeactivated(transition.owned()))
                case .deliver, .associationChanged:
                    break
                }
            }
            actionSink.removeAll()
        }
        guard case .accepted = outcome else {
            throw AxolotyError.runtime(
                code: .brokerUnavailable,
                reason: "lifecycle operation rejected by protocol: \(outcome)"
            )
        }

        for effect in effects {
            if emitApplicationEvents, case .publish(let publication) = effect {
                emitRegisteredEvents(for: publication, nowMS: nowMS)
            }
            try await transport.perform(effect.transportEffect(namespace: definition.namespace, profile: wireProfile))
        }
    }

    func publishLifecycleAdvertisement(nowMS: UInt32) async throws {
        guard let identity = definition.identity else { return }
        let operation = RuntimeOperation.advertise(
            sourceID: identity.id,
            payload: try RuntimeLifecyclePayload.advertise(identity, profile: wireProfile)
        )
        try await publishLifecycle(operation, nowMS: nowMS)
        lifecycleAdvertisementActive = true
    }

    func makeTransportLastWill() throws -> RuntimeTransportLastWill? {
        guard let identity = definition.identity else { return nil }
        let routingKey = try ProtocolRoutingKey(
            capability: .deadvertise,
            sourceID: identity.id
        )
        let topic = try CoatyRoute.route(
            for: routingKey,
            namespace: definition.namespace,
            profile: wireProfile
        )
        return try RuntimeTransportLastWill(
            topic: topic,
            payload: try RuntimeLifecyclePayload.deadvertise(identity, profile: wireProfile)
        )
    }

    func publishDeadvertisement(objectID: UUID16, sourceID: UUID16, nowMS: UInt32) async throws(AxolotyError) {
        let payload: [UInt8]
        do {
            payload = try RuntimeWirePayload.deadvertise(uuid: objectID, profile: wireProfile)
        } catch {
            throw .caught(error)
        }
        try await publishLifecycle(
            .deadvertise(sourceID: sourceID, payload: payload),
            nowMS: nowMS,
            emitApplicationEvents: false
        )
    }

    func publishLifecycleDeadvertisement(nowMS: UInt32) async throws(AxolotyError) {
        guard lifecycleAdvertisementActive, let identity = definition.identity else { return }
        try await publishDeadvertisement(objectID: identity.id, sourceID: identity.id, nowMS: nowMS)
        lifecycleAdvertisementActive = false
    }

    func processOutboundOperation(
        _ operation: RuntimeOperation,
        nowMS: UInt32,
        maximumActionCount: Int,
        consumeAcceptedActions: () -> Void
    ) -> ProtocolProcessOutcome {
        let operationNameBytes: [UInt8] = operation.operationName.map { Array($0.utf8) } ?? []
        return operation.payload.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return .rejected(.malformedPayload) }
            let payload = ByteSlice(bytes: base, length: buffer.count)
            return operationNameBytes.withUnsafeBufferPointer { operationBuffer in
                // An absent optional filter is represented by an empty
                // temporary buffer here; do not turn that buffer into a
                // present zero-length route segment.
                let operationName: ByteSlice? = operationBuffer.count == 0
                    ? nil
                    : operationBuffer.baseAddress.map {
                        ByteSlice(bytes: $0, length: operationBuffer.count)
                    }
                let local: ProtocolLocalOperation
                do {
                    local = try ProtocolLocalOperation(
                        capability: operation.capability,
                        sourceID: operation.sourceID,
                        correlationID: operation.correlationID,
                        payload: payload,
                        requestTimeoutMS: operation.requestTimeoutMS,
                        operationName: operationName
                    )
                } catch {
                    return .rejected(.invalidCorrelation)
                }
                actionSink.prepare(maximumActionCount: maximumActionCount)
                let outcome = processor.processOutbound(
                    local,
                    nowMS: nowMS,
                    classifier: TransportRouteClassifier(transport: transport),
                    sink: &actionSink
                )
                // The processor emits borrowed action views into `operation.payload`.
                // The caller must consume or own them before this buffer borrow ends.
                if case .accepted = outcome {
                    consumeAcceptedActions()
                }
                return outcome
            }
        }
    }
}
