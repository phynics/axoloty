// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyWire
import AxolotyZenohCore
import Foundation

enum ZenohBindingSupport {
    // One tick every 10 ms, with at most one façade queue capacity (four
    // polls) per subscription. Eight handles cap work per tick at 32 polls.
    static let receivePumpIntervalNanoseconds: UInt64 = 10_000_000
    static let receivePumpDrainLimit = 4

    static func monotonicNowMS() -> UInt32 {
        UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    static func validateNamespace(_ namespace: String) throws(AxolotyError) {
        let bytes = Array(namespace.utf8)
        guard (1...64).contains(bytes.count),
              !bytes.contains(where: { [0, 0x2F, 0x23, 0x2B, 0x2A].contains($0) }) else {
            throw AxolotyError.invalidArgument(
                argument: "namespace",
                reason: "must contain 1...64 UTF-8 bytes and no route separators or Zenoh wildcards"
            )
        }
    }

    static func profileInterestRoutes(namespace: String) -> [String] {
        [
            "coaty/3/\(namespace)/*/*",
            "coaty/3/\(namespace)/*/*/*",
        ]
    }

    static func classify(
        _ route: ByteSlice,
        activeNamespace: String?,
        maximumProfileKeyLength: Int
    ) -> ProtocolRouteClassification {
        guard route.length > 0, route.length <= WireBufferConfig.maxTopicLength else { return .unrelated }
        for index in 0..<route.length {
            guard let byte = route.byte(at: index),
                  byte != 0, byte != 0x23, byte != 0x2B, byte != 0x2A else {
                return .unrelated
            }
            if byte == 0x2F {
                guard index > 0, route.byte(at: index - 1) != 0x2F,
                      index + 1 < route.length, route.byte(at: index + 1) != 0x2F else {
                    return .unrelated
                }
            }
        }

        var bytes = [UInt8](repeating: 0, count: route.length)
        for index in 0..<route.length { bytes[index] = route.byte(at: index)! }
        guard bytes.starts(with: Array("coaty/3/".utf8)) else { return .external }
        guard route.length <= maximumProfileKeyLength, let activeNamespace else { return .unrelated }
        return bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return .unrelated }
            let topic = TopicView(topicBytes: base, length: buffer.count)
            guard (try? topic.validate(maximumTopicLength: maximumProfileKeyLength)) != nil,
                  topic.namespaceLevel.map({ equals($0, activeNamespace) }) == true,
                  let eventType = topic.eventType,
                  staticStringEquals(eventType.wireCode, "IOV") else {
                return .unrelated
            }
            return .coaty
        }
    }

    static func inboundFrame(
        routeBytes: [UInt8],
        payload: [UInt8],
        nowMS: UInt32,
        routeState: ZenohInboundRouteState
    ) -> RuntimeInboundFrame? {
        guard !routeBytes.isEmpty,
              routeBytes.count <= WireBufferConfig.maxTopicLength,
              !routeBytes.contains(where: { $0 == 0 || $0 == 0x23 || $0 == 0x2B || $0 == 0x2A }) else {
            return nil
        }
        guard let route = String(bytes: routeBytes, encoding: .utf8) else { return nil }
        if let activeNamespace = routeState.activeNamespace,
           routeBytes.count <= routeState.maximumProfileKeyLength,
           isActiveProfile(
               routeBytes,
               namespace: activeNamespace,
               maximumKeyLength: routeState.maximumProfileKeyLength
           ) {
            return .profile(route: route, payload: payload, nowMS: nowMS)
        }
        guard routeState.externalRoutes.contains(routeBytes) else { return nil }
        return .externalIo(route: route, payload: payload, nowMS: nowMS)
    }

    private static func isActiveProfile(
        _ routeBytes: [UInt8],
        namespace: String,
        maximumKeyLength: Int
    ) -> Bool {
        routeBytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            let topic = TopicView(topicBytes: base, length: buffer.count)
            guard (try? topic.validate(maximumTopicLength: maximumKeyLength)) != nil,
                  let actualNamespace = topic.namespaceLevel else { return false }
            return equals(actualNamespace, namespace)
        }
    }

    static func requireSuccess(_ result: ZenohResult, operation: String) throws(AxolotyError) {
        guard result == .success else { throw error(for: result, operation: operation) }
    }

    static func error(for result: ZenohResult, operation: String) -> AxolotyError {
        switch result {
        case .success:
            return .runtime(code: .cancelled, reason: "\(operation) unexpectedly reported success as a failure")
        case .invalidArgument:
            return .invalidArgument(argument: "Zenoh", reason: "\(operation) rejected a key or argument")
        case .notOpen:
            return .runtime(code: .notStarted, reason: "\(operation) requires an open Zenoh session")
        case .capacityExceeded, .queueFull:
            return .runtime(code: .capacityExceeded, reason: "\(operation) exceeded a bounded Zenoh capacity")
        case .transportError:
            return .runtime(code: .brokerUnavailable, reason: "\(operation) failed in the Zenoh transport")
        case .queueEmpty:
            return .runtime(code: .streamEnded, reason: "\(operation) had no queued Zenoh frame")
        case .frameTooLarge:
            return .invalidArgument(argument: "Zenoh", reason: "\(operation) exceeded the configured frame bound")
        }
    }

    static func failure(for error: AxolotyError) -> RuntimeTransportFailure {
        let code: AxolotyError.RuntimeErrorCode
        if case let .runtime(runtimeCode, _) = error {
            code = runtimeCode
        } else {
            code = .brokerUnavailable
        }
        return RuntimeTransportFailure(code: code, detail: error.userFriendlyMessage)
    }

    static func runtimeError(for error: ZenohBindingConfigurationError) -> AxolotyError {
        let option: String
        let reason: String
        switch error {
        case .invalidConnectEndpoint:
            option = "connectEndpoint"
            reason = "must contain 1...512 printable ASCII bytes excluding quote and backslash"
        case .maximumProfileKeyBytesOutOfRange:
            option = "maximumProfileKeyBytes"
            reason = "must be in 1...256"
        case .maximumExternalRoutesOutOfRange:
            option = "maximumExternalRoutes"
            reason = "must be in 1...\(ZenohBindingConfiguration.maximumExternalRouteCapacity)"
        case .receiveQueueCapacityOutOfRange:
            option = "receiveQueueCapacity"
            reason = "must be in 1...4"
        case .receiveKeyCapacityOutOfRange:
            option = "receiveKeyCapacity"
            reason = "must be in 1...\(ZenohFrameStorage.keyCapacity)"
        case .receivePayloadCapacityOutOfRange:
            option = "receivePayloadCapacity"
            reason = "must be in 1...\(ZenohFrameStorage.payloadCapacity)"
        }
        return .invalidConfiguration(option: option, reason: reason)
    }

    private static func staticStringEquals(_ value: StaticString, _ literal: StaticString) -> Bool {
        guard value.utf8CodeUnitCount == literal.utf8CodeUnitCount else { return false }
        for index in 0..<value.utf8CodeUnitCount where value.utf8Start[index] != literal.utf8Start[index] {
            return false
        }
        return true
    }

    private static func equals(_ slice: ByteSlice, _ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard slice.length == bytes.count else { return false }
        for index in bytes.indices where slice.byte(at: index) != bytes[index] { return false }
        return true
    }
}

struct ZenohInboundRouteState {
    let activeNamespace: String?
    let externalRoutes: [[UInt8]]
    let maximumProfileKeyLength: Int
}
