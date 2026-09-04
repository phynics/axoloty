// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyWire

// The executor owns handler supervision: registration matching, bounded
// concurrency, invocation lifecycle, and response publication.
extension ProtocolExecutor {
    func dispatchToHandler(_ action: OwnedProtocolAction, operation: String?) {
        guard let match = definition.registrations.handlers.enumerated().first(where: {
            guard $0.element.capability == action.capability else { return false }
            return $0.element.operation == nil || $0.element.operation == operation
        }) else {
            return
        }
        let registrationIndex = match.offset
        let registration = match.element
        guard activeHandlers < definition.capacities.handlersInFlight else {
            diagnosticsSnapshotValue.handlerSaturation += 1
            emit(.init(kind: .capacityExceeded, detail: "handler supervision capacity is full"))
            return
        }
        guard handlerInFlight[registrationIndex, default: 0] < registration.maximumConcurrentInvocations else {
            diagnosticsSnapshotValue.handlerSaturation += 1
            emit(.init(kind: .capacityExceeded, detail: "handler registration concurrency is full"))
            return
        }
        activeHandlers += 1
        handlerInFlight[registrationIndex, default: 0] += 1
        let handlerID = nextHandlerID
        nextHandlerID &+= 1
        let invocation = RuntimeInvocation(
            action: action,
            operation: operation,
            registrationIndex: registrationIndex,
            handlerID: handlerID
        )
        eventContinuation.yield(.invocation(invocation))
        let task = Task { [weak self] in
            do {
                let result = try await registration.handler(invocation)
                guard !Task.isCancelled else {
                    await self?.handlerCancelled(invocation)
                    return
                }
                await self?.complete(invocation: invocation, result: result)
            } catch is CancellationError {
                await self?.handlerCancelled(invocation)
            } catch {
                await self?.handlerFailed(
                    runtimeErrorDetail(error),
                    registrationIndex: registrationIndex
                )
            }
            await self?.handlerTaskFinished(handlerID)
        }
        handlerTasks[handlerID] = task
    }
    func complete(invocation: RuntimeInvocation, result: RuntimeHandlerResult) {
        activeHandlers = max(0, activeHandlers - 1)
        decrementHandler(registrationIndex: invocation.registrationIndex)
        let routingKey: ProtocolRoutingKey
        switch invocation.action {
        case .deliver(let value): routingKey = value.routingKey
        case .publish(let value): routingKey = value.routingKey
        case .associationChanged(let value): routingKey = value.delivery.routingKey
        case .externalRouteActivated, .externalRouteDeactivated: return
        }
        guard let correlation = routingKey.correlationID else { return }
        let responseCapability: ProtocolCapability
        switch routingKey.capability {
        case .discover: responseCapability = .resolve
        case .query: responseCapability = .retrieve
        case .update: responseCapability = .complete
        case .call: responseCapability = .returnEvent
        default:
            emit(.init(kind: .handlerFailed, detail: "handler completion is not a request family"))
            return
        }
        guard case let .response(payload) = result else {
            if case let .remoteError(code, message) = result {
                guard let payload = makeErrorResponsePayload(
                    capability: responseCapability,
                    code: code,
                    message: message
                ) else {
                    emit(.init(kind: .handlerFailed, detail: "remote error could not be encoded"))
                    return
                }
                _ = publish(
                    RuntimeOperation(
                        capability: responseCapability,
                        sourceID: definition.sourceID,
                        correlationID: correlation,
                        payload: payload
                    ),
                    nowMS: monotonicNowMS()
                )
            }
            return
        }
        _ = publish(
            RuntimeOperation(
                capability: responseCapability,
                sourceID: definition.sourceID,
                correlationID: correlation,
                payload: payload
            ),
            nowMS: monotonicNowMS()
        )
    }
    func handlerFailed(_ detail: String, registrationIndex: Int = -1) {
        activeHandlers = max(0, activeHandlers - 1)
        decrementHandler(registrationIndex: registrationIndex)
        emit(.init(kind: .handlerFailed, detail: detail))
    }
    func handlerCancelled(_ invocation: RuntimeInvocation) {
        activeHandlers = max(0, activeHandlers - 1)
        decrementHandler(registrationIndex: invocation.registrationIndex)
    }

    func handlerTaskFinished(_ handlerID: UInt64) {
        handlerTasks.removeValue(forKey: handlerID)
    }

    func cancelAndDrainHandlers() async {
        let tasks = Array(handlerTasks.values)
        handlerTasks.removeAll(keepingCapacity: true)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        activeHandlers = 0
        handlerInFlight.removeAll(keepingCapacity: true)
    }

    func decrementHandler(registrationIndex: Int) {
        guard registrationIndex >= 0 else { return }
        let remaining = max(0, handlerInFlight[registrationIndex, default: 0] - 1)
        if remaining == 0 {
            handlerInFlight.removeValue(forKey: registrationIndex)
        } else {
            handlerInFlight[registrationIndex] = remaining
        }
    }
}
