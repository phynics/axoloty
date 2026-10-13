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
        let profile = wireProfile
        let errorBytes: [UInt8]
        let emptyObject: [UInt8]
        let emptyArray: [UInt8]
        switch profile {
        case .coaty3JSON:
            guard let error = try? JSONSerialization.data(
                withJSONObject: ["code": code, "message": message],
                options: [.sortedKeys]
            ) else { return nil }
            errorBytes = Array(error)
            emptyObject = Array("{}".utf8)
            emptyArray = Array("[]".utf8)
        case .axoloty1CBOR:
            guard let error = try? RuntimeWirePayload.cborErrorObject(code: code, message: message),
                  let object = try? RuntimeWirePayload.emptyObject(profile: .axoloty1CBOR),
                  let array = try? RuntimeWirePayload.emptyArray(profile: .axoloty1CBOR) else {
                return nil
            }
            errorBytes = error
            emptyObject = object
            emptyArray = array
        }
        let event: OwnedWireEvent?
        switch capability {
        case .resolve:
            event = try? .resolve(OwnedResolveWireData(
                profile: profile,
                object: emptyObject,
                relatedObjects: nil,
                privateData: errorBytes
            ))
        case .retrieve:
            event = try? .retrieve(OwnedRetrieveWireData(
                profile: profile,
                objects: emptyArray,
                privateData: errorBytes
            ))
        case .complete:
            event = try? .complete(OwnedCompleteWireData(profile: profile, object: nil, privateData: errorBytes))
        case .returnEvent:
            event = try? .returnEvent(OwnedReturnWireData(profile: profile, result: nil, executionInfo: nil, error: errorBytes))
        default:
            event = nil
        }
        return try? event?.encodedBytes(capacity: 1024)
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
