// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyWire
import ErrorKit
import Foundation
import NIOConcurrencyHelpers

extension OwnedProtocolAction {
    var capability: ProtocolCapability {
        switch self {
        case .deliver(let value): return value.routingKey.capability
        case .publish(let value): return value.routingKey.capability
        case .associationChanged(let value): return value.delivery.routingKey.capability
        case .externalRouteActivated, .externalRouteDeactivated: return .associate
        }
    }

    var isPublication: Bool {
        if case .publish = self { return true }
        return false
    }
}

struct TransportRouteClassifier: ProtocolRouteClassifier {
    let transport: any AxolotyRuntimeTransport

    func classify(_ route: ByteSlice) -> ProtocolRouteClassification {
        transport.classifyRoute(route)
    }
}

func runtimeErrorDetail(_ error: Error) -> String {
    let wrapped = error as? AxolotyError ?? AxolotyError.caught(error)
    return ErrorKit.errorChainDescription(for: wrapped)
}

func monotonicNowMS() -> UInt32 {
    UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
}

final class RuntimeOverflowGate: @unchecked Sendable {
    private let lock = NIOLock()
    private var signaled = false

    func reset() {
        lock.withLock { signaled = false }
    }

    func claim() -> Bool {
        lock.withLock {
            guard !signaled else { return false }
            signaled = true
            return true
        }
    }
}

extension ByteSlice {
    func utf8Equals(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == length else { return false }
        for index in 0..<length where byte(at: index) != bytes[index] {
            return false
        }
        return true
    }
}
