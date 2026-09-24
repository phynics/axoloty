// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyWire
import ErrorKit
import Foundation
import Synchronization

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

/// A once-only saturation latch.
///
/// Claimed from a transport receive callback, which may run on a transport
/// event-loop thread, so it cannot be an actor. It was the host runtime's only
/// use of NIO outside the transport itself.
final class RuntimeOverflowGate: Sendable {
    private let signaled = Mutex(false)

    func reset() {
        signaled.withLock { $0 = false }
    }

    func claim() -> Bool {
        signaled.withLock { signaled in
            guard !signaled else { return false }
            signaled = true
            return true
        }
    }
}

extension OwnedWireEvent {
    /// Encodes this event into a new, exactly sized byte array.
    ///
    /// Package-visible so first-party runtime modules share one owned-event
    /// encoder without this becoming public API.
    ///
    /// - Parameter capacity: The largest encoding accepted, in bytes.
    /// - Returns: The encoded JSON payload.
    /// - Throws: ``WireEncodeError/bufferOverflow`` if the encoding exceeds `capacity`.
    package func encodedBytes(
        capacity: Int = WireBufferConfig.maxPayloadSize
    ) throws(WireEncodeError) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: capacity)
        var result: Result<Int, WireEncodeError> = .failure(.bufferOverflow)
        output.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var writer = WireWriter(buffer: baseAddress, capacity: buffer.count)
            do throws(WireEncodeError) {
                try encode(to: &writer)
                result = .success(writer.position)
            } catch {
                result = .failure(error)
            }
        }
        let length = try result.get()
        output.removeSubrange(length..<output.count)
        return output
    }
}

extension ByteSlice {
    /// Package-visible so the transport adapter can compare a borrowed route
    /// against a literal without this becoming public API.
    package func utf8Equals(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == length else { return false }
        for index in 0..<length where byte(at: index) != bytes[index] {
            return false
        }
        return true
    }
}
