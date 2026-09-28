// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyWire
import AxolotyZenohCore

struct ExternalSubscription {
    let route: [UInt8]
    let subscription: Int
    var referenceCount: Int
}

protocol ZenohBindingSession: AnyObject {
    func open(endpoint: [UInt8]) -> ZenohResult
    func close() -> ZenohResult
    func publish(route: [UInt8], payload: [UInt8]) -> ZenohResult
    func subscribe(route: [UInt8]) throws(AxolotyError) -> Int
    func unsubscribe(_ subscription: Int) -> ZenohResult
    func poll(_ subscription: Int, into storage: inout ZenohFrameStorage) -> ZenohPollResult
    func connectedRouterCount() -> ZenohRouterCountResult
}

/// Couples the move-only Swift session with its opaque façade handles.
///
/// The binding's process-wide registry lock serializes every call to this owner.
final class ZenohFacadeSession: ZenohBindingSession {
    private var session = ZenohSession()
    private var subscriptions: [(id: Int, handle: ZenohSubscription)] = []
    private var nextSubscriptionID = 0

    func open(endpoint: [UInt8]) -> ZenohResult {
        withSlice(endpoint) { endpointSlice in
            session.open(configuration: ZenohConfiguration(connectEndpoint: endpointSlice))
        }
    }

    func close() -> ZenohResult {
        subscriptions.removeAll(keepingCapacity: true)
        return session.close()
    }

    func publish(route: [UInt8], payload: [UInt8]) -> ZenohResult {
        withSlice(route) { routeSlice in
            withSlice(payload) { payloadSlice in
                session.publish(key: routeSlice, payload: payloadSlice)
            }
        }
    }

    func subscribe(route: [UInt8]) throws(AxolotyError) -> Int {
        let result = withSlice(route) { routeSlice in session.subscribe(key: routeSlice) }
        switch result {
        case let .subscribed(handle):
            repeat {
                nextSubscriptionID = nextSubscriptionID == .max ? 1 : nextSubscriptionID + 1
            } while subscriptions.contains(where: { $0.id == nextSubscriptionID })
            subscriptions.append((nextSubscriptionID, handle))
            return nextSubscriptionID
        case let .result(result):
            throw ZenohBindingSupport.error(for: result, operation: "Zenoh subscription")
        }
    }

    func unsubscribe(_ subscription: Int) -> ZenohResult {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription }) else {
            return .invalidArgument
        }
        let result = session.unsubscribe(subscriptions[index].handle)
        if result == .success { subscriptions.remove(at: index) }
        return result
    }

    func poll(_ subscription: Int, into storage: inout ZenohFrameStorage) -> ZenohPollResult {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription }) else {
            return .result(.invalidArgument)
        }
        return session.poll(from: subscriptions[index].handle, into: &storage)
    }

    func connectedRouterCount() -> ZenohRouterCountResult {
        session.connectedRouterCount()
    }

    private func withSlice<R>(_ bytes: [UInt8], _ body: (ByteSlice) -> R) -> R {
        bytes.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                return body(ByteSlice(bytes: base, length: buffer.count))
            }
            var empty: UInt8 = 0
            return withUnsafePointer(to: &empty) { body(ByteSlice(bytes: $0, length: 0)) }
        }
    }
}
