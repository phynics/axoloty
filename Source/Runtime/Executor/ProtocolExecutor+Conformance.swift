// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyWire
import Foundation

extension ProtocolExecutor {
    func makeErrorResponsePayload(
        capability: ProtocolCapability,
        code: UInt16,
        message: String
    ) -> [UInt8]? {
        guard let error = try? JSONSerialization.data(
            withJSONObject: ["code": code, "message": message],
            options: [.sortedKeys]
        ) else { return nil }
        let errorBytes = Array(error)
        let event: OwnedWireEvent?
        switch capability {
        case .resolve:
            event = try? .resolve(OwnedResolveWireData(object: Array("{}".utf8), relatedObjects: nil, privateData: errorBytes))
        case .retrieve:
            event = try? .retrieve(OwnedRetrieveWireData(objects: Array("[]".utf8), privateData: errorBytes))
        case .complete:
            event = try? .complete(OwnedCompleteWireData(object: nil, privateData: errorBytes))
        case .returnEvent:
            event = try? .returnEvent(OwnedReturnWireData(result: nil, executionInfo: nil, error: errorBytes))
        default:
            event = nil
        }
        guard let event else { return nil }

        var output = [UInt8](repeating: 0, count: 1024)
        guard let length = output.withUnsafeMutableBufferPointer({ buffer -> Int? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            var writer = WireWriter(buffer: baseAddress, capacity: buffer.count)
            guard (try? event.encode(to: &writer)) != nil else { return nil }
            return writer.position
        }) else { return nil }
        output.removeSubrange(length..<output.count)
        return output
    }

    func receipt(for outcome: ProtocolProcessOutcome) -> RuntimeReceipt {
        switch outcome {
        case .accepted: return .accepted
        case .ignored: return .ignored
        case .rejected(.capacityExceeded): return .rejected(.capacityExceeded)
        case let .rejected(code): return .rejected(.protocol(code))
        }
    }

    func conformanceObservation() -> RuntimeConformanceObservation {
        var projection = ProtocolFixedStateSnapshot<64>()
        processor.copyState(into: &projection)
        var objects: [UUID16] = []
        var correlations: [UUID16] = []
        var associations: [UUID16] = []
        for index in 0..<projection.activeObjectCount {
            if let value = projection.activeObjectIDs[index] { objects.append(value) }
        }
        for index in 0..<projection.pendingCorrelationCount {
            if let value = projection.pendingCorrelationIDs[index] { correlations.append(value) }
        }
        for index in 0..<projection.associationCount {
            if let value = projection.associationSourceIDs[index] { associations.append(value) }
        }
        let state = RuntimeConformanceState(
            activeObjectIDs: objects,
            pendingCorrelationIDs: correlations,
            associationSourceIDs: associations,
            generation: processor.state.generation
        )
        let result = RuntimeConformanceObservation(actions: conformanceActions, state: state)
        conformanceActions.removeAll(keepingCapacity: true)
        return result
    }
}
