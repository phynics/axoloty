// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyWire
import AxolotyZenohCore

struct ZenohReceiveDrain {
    let callback: (@Sendable (RuntimeInboundFrame) -> Void)?
    let frames: [RuntimeInboundFrame]
    let failure: RuntimeTransportFailure?
    let recovered: Bool
    let isActive: Bool
}

extension ZenohBinding {
    /// Performs one deterministic bounded receive-pump tick.
    ///
    /// Tests use this seam to drain queued frames without waiting for the
    /// scheduled 10 ms pump interval.
    @discardableResult
    func drainReceiveQueues() -> Bool {
        let outcome = Self.sessionRegistryLock.withLock { drainReceiveQueuesLocked() }
        guard let callback = outcome.callback else { return false }
        for frame in outcome.frames { callback(frame) }
        if let failure = outcome.failure {
            reportFailure(failure)
        }
        if outcome.recovered { reportRecovery() }
        return outcome.isActive
    }

    func startReceivePumpLocked() {
        let pumpInterval = receivePumpIntervalNanoseconds
        receivePump = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: pumpInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard self?.drainReceiveQueues() == true else { return }
            }
        }
    }

    private func drainReceiveQueuesLocked() -> ZenohReceiveDrain {
        guard started, let callback = receive else {
            return ZenohReceiveDrain(callback: nil, frames: [], failure: nil, recovered: false, isActive: false)
        }
        let subscriptions = profileSubscriptions + externalSubscriptions.map(\.subscription)
        let routeState = ZenohInboundRouteState(
            activeNamespace: activeNamespace,
            externalRoutes: externalSubscriptions.map(\.route),
            maximumProfileKeyLength: configuration.maximumProfileKeyBytes
        )
        var frames: [RuntimeInboundFrame] = []
        var storage = ZenohFrameStorage()
        let connectivity = pollRouterConnectivityLocked()
        var failure = connectivity.failure
        var isActive = true

        for subscription in subscriptions {
            if let pollFailure = pollSubscription(
                subscription,
                routeState: routeState,
                storage: &storage,
                frames: &frames
            ) {
                failure = pollFailure
                isActive = false
                break
            }
        }
        return ZenohReceiveDrain(
            callback: callback,
            frames: frames,
            failure: failure,
            recovered: connectivity.recovered,
            isActive: isActive
        )
    }

    private func pollRouterConnectivityLocked() -> (failure: RuntimeTransportFailure?, recovered: Bool) {
        switch session.connectedRouterCount() {
        case let .count(count) where count > 0:
            let recovered = routerLossReported
            hasObservedRouter = true
            routerLossBeganAtNanoseconds = nil
            routerLossReported = false
            return (nil, recovered)
        case .count, .failure:
            return observeRouterAbsence()
        }
    }

    private func observeRouterAbsence() -> (failure: RuntimeTransportFailure?, recovered: Bool) {
        guard hasObservedRouter else { return (nil, false) }
        let now = monotonicNowNanoseconds()
        if let began = routerLossBeganAtNanoseconds {
            guard !routerLossReported, now &- began >= routerLossDebounceNanoseconds else {
                return (nil, false)
            }
        } else {
            routerLossBeganAtNanoseconds = now
            return (nil, false)
        }
        routerLossReported = true
        return (
            RuntimeTransportFailure(
                code: .brokerUnavailable,
                detail: Self.routerLossFailureDetail
            ),
            false
        )
    }

    private func pollSubscription(
        _ subscription: Int,
        routeState: ZenohInboundRouteState,
        storage: inout ZenohFrameStorage,
        frames: inout [RuntimeInboundFrame]
    ) -> RuntimeTransportFailure? {
        for _ in 0..<ZenohBindingSupport.receivePumpDrainLimit {
            switch session.poll(subscription, into: &storage) {
            case let .frame(frame):
                if let inbound = copyFrame(frame, from: storage, routeState: routeState) {
                    frames.append(inbound)
                }
            case .result(.queueEmpty):
                return nil
            case .result(.queueFull), .result(.frameTooLarge):
                continue
            case let .result(result):
                return ZenohBindingSupport.failure(for: ZenohBindingSupport.error(
                    for: result,
                    operation: "Zenoh receive poll"
                ))
            }
        }
        return nil
    }

    private func copyFrame(
        _ frame: ZenohFrame,
        from storage: ZenohFrameStorage,
        routeState: ZenohInboundRouteState
    ) -> RuntimeInboundFrame? {
        let key = storage.withKeyBytes(Self.copyBytes)
        let payload = storage.withPayloadBytes(Self.copyBytes)
        guard frame.keyLength == key.count, frame.payloadLength == payload.count else { return nil }
        return ZenohBindingSupport.inboundFrame(
            routeBytes: key,
            payload: payload,
            nowMS: clock(),
            routeState: routeState
        )
    }

    private static func copyBytes(_ slice: ByteSlice) -> [UInt8] {
        (0..<slice.length).map { slice.byte(at: $0)! }
    }
}
