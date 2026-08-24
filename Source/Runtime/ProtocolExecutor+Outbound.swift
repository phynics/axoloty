// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyWire

extension ProtocolExecutor {
    /// Processes a lifecycle operation through the portable processor and
    /// sends the resulting owned publications synchronously. Lifecycle sends
    /// must complete before startup/reconnect becomes ready or shutdown removes
    /// subscriptions, while ordinary publications continue through the
    /// bounded outbound pump.
    func publishLifecycle(_ operation: RuntimeOperation, nowMS: UInt32) async throws {
        var publications: [OwnedProtocolPublication] = []
        let outcome = processOutboundOperation(
            operation,
            nowMS: nowMS,
            maximumActionCount: definition.capacities.dispatch
        ) {
            publications.reserveCapacity(actionSink.count)
            for index in 0..<actionSink.count {
                guard let action = actionSink[index] else { continue }
                if case .publish(let publication) = action {
                    publications.append(publication.owned())
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

        for publication in publications {
            try await transport.send(publication, namespace: definition.namespace)
        }
    }

    func publishLifecycleAdvertisement(nowMS: UInt32) async throws {
        guard let identity = definition.identity else { return }
        let operation = RuntimeOperation.advertise(
            sourceID: identity.id,
            payload: try RuntimeLifecyclePayload.advertise(identity)
        )
        try await publishLifecycle(operation, nowMS: nowMS)
        lifecycleAdvertisementActive = true
    }

    func publishLifecycleDeadvertisement(nowMS: UInt32) async throws {
        guard lifecycleAdvertisementActive, let identity = definition.identity else { return }
        let operation = RuntimeOperation.deadvertise(
            sourceID: identity.id,
            payload: RuntimeLifecyclePayload.deadvertise(identity)
        )
        try await publishLifecycle(operation, nowMS: nowMS)
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
                let operationName = operationBuffer.baseAddress.map {
                    ByteSlice(bytes: $0, length: operationBuffer.count)
                }
                guard let local = try? ProtocolLocalOperation(
                    capability: operation.capability,
                    sourceID: operation.sourceID,
                    correlationID: operation.correlationID,
                    payload: payload,
                    requestTimeoutMS: operation.requestTimeoutMS,
                    operationName: operationName
                ) else {
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
