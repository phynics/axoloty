// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyWire
import Foundation

private let measurementCapacities = [1, 16, 64]
private let objectBytes: StaticString = "{\"a\":0}"
private let envelopeBytes: StaticString = "{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.Measurement\",\"name\":\"\",\"coreType\":\"Task\",\"externalId\":\"x\"}"
private let oversizedValue: StaticString = "999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999"

private struct LayoutRecord: Encodable {
    let capacity: Int
    let type: String
    let size: Int
    let alignment: Int
    let stride: Int
}

private struct OperationRecord: Encodable {
    let capacity: Int
    let objectInitialization: String
    let envelopeInitialization: Bool
    let randomizedEditRead: Bool
    let saturationMeasurement: String
    let saturationRejected: Bool
    let unchangedAfterSaturation: Bool
}

private struct ProbeReport: Encodable {
    let schemaVersion = 1
    let evidenceKind = "object-model-probe"
    let measurementCapacities: [Int]
    let capacityPolicy = "measurement-points-only"
    let layouts: [LayoutRecord]
    let operations: [OperationRecord]
}

private enum AllocationCase: String {
    case objectInitialization = "object-initialization"
    case objectWarmed = "object-warmed"
    case envelopeInitialization = "envelope-initialization"
    case envelopeWarmed = "envelope-warmed"
}

nonisolated(unsafe) private var allocationSink: UInt64 = 0

private func slice(_ value: StaticString) -> ByteSlice {
    ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount)
}

private func objectLayout<let capacity: Int>(_: BoundedDynamicObject<capacity, capacity>.Type) -> LayoutRecord {
    LayoutRecord(
        capacity: capacity,
        type: "BoundedDynamicObject<\(capacity),\(capacity)>",
        size: MemoryLayout<BoundedDynamicObject<capacity, capacity>>.size,
        alignment: MemoryLayout<BoundedDynamicObject<capacity, capacity>>.alignment,
        stride: MemoryLayout<BoundedDynamicObject<capacity, capacity>>.stride
    )
}

private func envelopeLayout<let capacity: Int>(_: ObjectEnvelope<capacity, capacity>.Type) -> LayoutRecord {
    LayoutRecord(
        capacity: capacity,
        type: "ObjectEnvelope<\(capacity),\(capacity)>",
        size: MemoryLayout<ObjectEnvelope<capacity, capacity>>.size,
        alignment: MemoryLayout<ObjectEnvelope<capacity, capacity>>.alignment,
        stride: MemoryLayout<ObjectEnvelope<capacity, capacity>>.stride
    )
}

private func envelopeInitialization<let capacity: Int>(_: ObjectEnvelope<capacity, capacity>.Type) -> Bool {
    do throws(ObjectError) {
        _ = try ObjectEnvelope<capacity, capacity>(decoding: slice(envelopeBytes))
        return true
    } catch {
        return false
    }
}

private func randomizedEditRead<let capacity: Int>(_: BoundedDynamicObject<capacity, capacity>.Type) -> Bool {
    guard var object = try? BoundedDynamicObject<capacity, capacity>(decoding: slice(objectBytes)) else { return false }
    var seed: UInt64 = 0x41584f4c4f5459
    for _ in 0..<2_000 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        do {
            if seed & 1 == 0 {
                try object.edit { try $0.setNull("a") }
            } else {
                try object.edit { try $0.set("a", to: .number("1")) }
            }
        } catch {
            return false
        }
        var observed: Presence<JSONValueKind> = .missing
        object.withFields { fields in observed = fields.presence(for: "a") }
        switch (seed & 1, observed) {
        case (0, .null), (1, .value(.number)):
            break
        default:
            return false
        }
    }
    return true
}

private func isNull(_ presence: Presence<JSONValueKind>) -> Bool {
    if case .null = presence { return true }
    return false
}

private func saturation<let capacity: Int>(_: BoundedDynamicObject<capacity, capacity>.Type) -> (rejected: Bool, unchanged: Bool) {
    guard var object = try? BoundedDynamicObject<capacity, capacity>(decoding: slice(objectBytes)) else {
        return (true, true)
    }
    let before = object.encodedEquals("{\"a\":0}")
    var rejected = false
    do {
        try object.edit { editor in try editor.setRaw("overflow", value: slice(oversizedValue)) }
    } catch let error as ObjectError {
        rejected = error.reason == .capacityExceeded
    } catch {
        rejected = false
    }
    return (rejected, before && object.encodedEquals("{\"a\":0}"))
}

private func operationRecord<let capacity: Int>(_: BoundedDynamicObject<capacity, capacity>.Type) -> OperationRecord {
    let initialization: String
    do throws(ObjectError) {
        _ = try BoundedDynamicObject<capacity, capacity>(decoding: slice(objectBytes))
        initialization = "accepted"
    } catch {
        initialization = "rejected-\(error.reason)"
    }
    let saturationResult = saturation(BoundedDynamicObject<capacity, capacity>.self)
    return OperationRecord(
        capacity: capacity,
        objectInitialization: initialization,
        envelopeInitialization: envelopeInitialization(ObjectEnvelope<capacity, capacity>.self),
        randomizedEditRead: randomizedEditRead(BoundedDynamicObject<capacity, capacity>.self),
        saturationMeasurement: capacity == 1 ? "minimum-object-rejection" : "edit-capacity-failure",
        saturationRejected: saturationResult.rejected,
        unchangedAfterSaturation: saturationResult.unchanged
    )
}

private func report() -> ProbeReport {
    ProbeReport(
        measurementCapacities: measurementCapacities,
        layouts: [
            objectLayout(BoundedDynamicObject<1, 1>.self), envelopeLayout(ObjectEnvelope<1, 1>.self),
            objectLayout(BoundedDynamicObject<16, 16>.self), envelopeLayout(ObjectEnvelope<16, 16>.self),
            objectLayout(BoundedDynamicObject<64, 64>.self), envelopeLayout(ObjectEnvelope<64, 64>.self),
        ],
        operations: [
            operationRecord(BoundedDynamicObject<1, 1>.self),
            operationRecord(BoundedDynamicObject<16, 16>.self),
            operationRecord(BoundedDynamicObject<64, 64>.self),
        ]
    )
}

private func allocationRun<let capacity: Int>(_: BoundedDynamicObject<capacity, capacity>.Type, _ allocationCase: AllocationCase, iterations: Int) {
    switch allocationCase {
    case .objectInitialization:
        for index in 0..<iterations {
            do {
                let object = try BoundedDynamicObject<capacity, capacity>(decoding: slice(objectBytes))
                allocationSink &+= UInt64(index) + (object.encodedEquals("{\"a\":0}") ? 1 : 0)
            } catch {
                allocationSink &+= UInt64(index)
            }
        }
    case .objectWarmed:
        guard var object = try? BoundedDynamicObject<capacity, capacity>(decoding: slice(objectBytes)) else { return }
        for _ in 0..<iterations {
            try? object.edit { try $0.setNull("a") }
            object.withFields { fields in allocationSink &+= isNull(fields.presence(for: "a")) ? 1 : 0 }
            try? object.edit { try $0.set("a", to: .number("1")) }
        }
    case .envelopeInitialization:
        for index in 0..<iterations {
            do {
                let envelope = try ObjectEnvelope<capacity, capacity>(decoding: slice(envelopeBytes))
                allocationSink &+= UInt64(index) + UInt64(envelope.name.length)
            } catch {
                allocationSink &+= UInt64(index)
            }
        }
    case .envelopeWarmed:
        guard let envelope = try? ObjectEnvelope<capacity, capacity>(decoding: slice(envelopeBytes)) else { return }
        for _ in 0..<iterations { allocationSink &+= UInt64(envelope.name.length) + (envelope.isDeactivated ? 1 : 0) }
    }
}

private func runAllocationCase(_ allocationCase: AllocationCase, capacity: Int, iterations: Int) {
    switch capacity {
    case 1: allocationRun(BoundedDynamicObject<1, 1>.self, allocationCase, iterations: iterations)
    case 16: allocationRun(BoundedDynamicObject<16, 16>.self, allocationCase, iterations: iterations)
    case 64: allocationRun(BoundedDynamicObject<64, 64>.self, allocationCase, iterations: iterations)
    default: fatalError("unsupported measurement capacity")
    }
    print(allocationSink)
}

if let caseIndex = CommandLine.arguments.firstIndex(of: "--allocation-case") {
    let allocationCase = AllocationCase(rawValue: CommandLine.arguments[caseIndex + 1])!
    let capacityIndex = CommandLine.arguments.firstIndex(of: "--capacity")!
    let iterationsIndex = CommandLine.arguments.firstIndex(of: "--iterations")!
    runAllocationCase(
        allocationCase,
        capacity: Int(CommandLine.arguments[capacityIndex + 1])!,
        iterations: Int(CommandLine.arguments[iterationsIndex + 1])!
    )
} else {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(data: try! encoder.encode(report()), encoding: .utf8)!)
}
