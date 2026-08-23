// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyCoatyModels
import AxolotyWire
import Foundation

private let measurementPoints = [1, 16, 64]
private let objectBytes: StaticString = "{\"a\":0}"
private let envelopeBytes: StaticString = "{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.Measurement\",\"name\":\"M\",\"coreType\":\"Task\",\"externalId\":\"x\"}"
private let oversizedValue: StaticString = "999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999"
private let ioSourceBytes: StaticString = "{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"coaty.IoSource\",\"name\":\"source\",\"coreType\":\"IoSource\",\"valueType\":\"T\"}"
private let predicateBytes: StaticString = "{\"conditions\":[\"value\",[7,1]]}"

private struct LayoutRecord: Encodable {
    let measurementPoint: Int
    let axis: String
    let type: String
    let size: Int
    let alignment: Int
    let stride: Int
    let byteCapacity: Int?
    let fieldCapacity: Int?
    let nameCapacity: Int?
    let externalIDCapacity: Int?
}

private struct OperationRecord: Encodable {
    let measurementPoint: Int
    let byteCapacity: Int
    let fieldCapacity: Int
    let nameCapacity: Int
    let externalIDCapacity: Int
    let objectInitialization: String
    let envelopeInitialization: Bool
    let randomizedEditRead: Bool
    let saturationMeasurement: String
    let saturationRejected: Bool
    let unchangedAfterSaturation: Bool
    let schemaRegistration: String
    let schemaRegistryCount: Int
    let schemaRegistrySaturated: Bool
    let schemaRegistryUnchangedAfterSaturation: Bool
    let typedObjectInitialization: String
    let typedObjectValueTypePreserved: Bool
    let typedObjectByteCapacity: Int
    let typedObjectFieldCapacity: Int
    let predicateInitialization: String
    let predicateDecodeEvaluateEncode: Bool
    let predicateRoundTrip: Bool
}

private struct SchemaLayoutRecord: Encodable {
    let measurementPoint: Int
    let axis = "schema-registry"
    let type: String
    let size: Int
    let alignment: Int
    let stride: Int
    let registryCapacity: Int
}

private struct PredicateLayoutRecord: Encodable {
    let measurementPoint: Int
    let axis = "predicate"
    let type: String
    let size: Int
    let alignment: Int
    let stride: Int
    let nodeCapacity: Int
    let pathCapacity: Int
    let literalCapacity: Int
    let arenaCapacity: Int
}

private struct ProbeReport: Encodable {
    let schemaVersion = 1
    let evidenceKind = "object-model-probe"
    let measurementPoints: [Int]
    let measurementPolicy = "simultaneous-object-envelope-schema-model-specializations"
    let layouts: [LayoutRecord]
    let schemaLayouts: [SchemaLayoutRecord]
    let predicateLayouts: [PredicateLayoutRecord]
    let operations: [OperationRecord]
}

private enum AllocationCase: String {
    case objectInitialization = "object-initialization"
    case objectWarmed = "object-warmed"
    case envelopeInitialization = "envelope-initialization"
    case envelopeWarmed = "envelope-warmed"
    case schemaRegistryInitialization = "schema-registry-initialization"
    case typedObjectInitialization = "typed-object-initialization"
    case typedObjectWarmed = "typed-object-warmed"
    case predicateInitialization = "predicate-initialization"
    case predicateWarmed = "predicate-warmed"
}

nonisolated(unsafe) private var allocationSink: UInt64 = 0

private func slice(_ value: StaticString) -> ByteSlice {
    ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount)
}

private func objectLayout<let capacity: Int>(_: BoundedDynamicObject<capacity, capacity>.Type) -> LayoutRecord {
    LayoutRecord(
        measurementPoint: capacity,
        axis: "object",
        type: "BoundedDynamicObject<\(capacity),\(capacity)>",
        size: MemoryLayout<BoundedDynamicObject<capacity, capacity>>.size,
        alignment: MemoryLayout<BoundedDynamicObject<capacity, capacity>>.alignment,
        stride: MemoryLayout<BoundedDynamicObject<capacity, capacity>>.stride,
        byteCapacity: capacity,
        fieldCapacity: capacity,
        nameCapacity: nil,
        externalIDCapacity: nil
    )
}

private func envelopeLayout<let capacity: Int>(_: ObjectEnvelope<capacity, capacity>.Type) -> LayoutRecord {
    LayoutRecord(
        measurementPoint: capacity,
        axis: "envelope",
        type: "ObjectEnvelope<\(capacity),\(capacity)>",
        size: MemoryLayout<ObjectEnvelope<capacity, capacity>>.size,
        alignment: MemoryLayout<ObjectEnvelope<capacity, capacity>>.alignment,
        stride: MemoryLayout<ObjectEnvelope<capacity, capacity>>.stride,
        byteCapacity: nil,
        fieldCapacity: nil,
        nameCapacity: capacity,
        externalIDCapacity: capacity
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

private func schemaRegistryOperation<let capacity: Int>(_: ObjectSchemaRegistry<capacity>.Type) -> (registration: String, count: Int, saturated: Bool, unchangedAfterSaturation: Bool) {
    var registry = ObjectSchemaRegistry<capacity>()
    var registration = "accepted"
    do throws(ObjectSchemaRegistryError) {
        try registry.use(IoSource.self)
        try registry.use(IoActor.self)
        try registry.use(CoatyObject.self)
        try registry.use(IoContext.self)
    } catch {
        registration = "rejected-\(error)"
    }
    var saturated = false
    let expectedCountAfterRegistration = capacity == 1 ? 1 : 4
    do throws(ObjectSchemaRegistryError) {
        if capacity == 1 {
            // IoActor was not admitted after IoSource filled the one-slot
            // registry, so this probes capacity rather than idempotency.
            try registry.use(IoActor.self)
        } else {
            // Larger points intentionally exercise idempotent registration;
            // they are not expected to be saturated.
            try registry.use(IoSource.self)
        }
    } catch .capacityExceeded {
        saturated = true
    } catch {
        // A non-capacity outcome is not saturation evidence.
    }
    let sealed = registry.sealed()
    return (registration, sealed.count, saturated, saturated && sealed.count == expectedCountAfterRegistration)
}

private func typedObjectOperation<let fieldCapacity: Int>(_: BoundedObject<IoSource, 512, fieldCapacity>.Type) -> (initialization: String, valueTypePreserved: Bool) {
    do throws(ObjectError) {
        let object = try BoundedObject<IoSource, 512, fieldCapacity>(decoding: slice(ioSourceBytes))
        return ("accepted", object.value.valueType.encodedEquals("T"))
    } catch {
        return ("rejected-\(error.reason)", false)
    }
}

private func predicateOperation<let capacity: Int>(_: ObjectPredicate<capacity, capacity, capacity, capacity>.Type) -> (initialization: String, roundTrip: Bool, decodeEvaluateEncode: Bool) {
    do throws(ObjectError) {
        let predicate = try ObjectPredicate<capacity, capacity, capacity, capacity>(decoding: slice(predicateBytes))
        let object = try BoundedDynamicObject<capacity, capacity>(decoding: slice("{\"value\":1}"))
        let matched = predicate.matches(object: object)
        var output = [UInt8](repeating: 0, count: 128)
        let encoded: (canonical: Bool, decodedMatches: Bool)
        do {
            encoded = try output.withUnsafeMutableBufferPointer { buffer -> (canonical: Bool, decodedMatches: Bool) in
                var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
                try predicate.encode(to: &writer)
                let outputSlice = ByteSlice(bytes: buffer.baseAddress!, length: writer.position)
                let decoded = try ObjectPredicate<capacity, capacity, capacity, capacity>(decoding: outputSlice)
                return (outputSlice.equals(predicateBytes), decoded.matches(object: object))
            }
        } catch {
            let mapped = (error as? ObjectError) ?? ObjectError(.invalidPredicate)
            return ("rejected-\(mapped.reason)", false, false)
        }
        return ("accepted", encoded.canonical && encoded.decodedMatches, matched && encoded.canonical)
    } catch {
        return ("rejected-\(error.reason)", false, false)
    }
}

private func isNull(_ presence: Presence<JSONValueKind>) -> Bool {
    if case .null = presence { return true }
    return false
}

private func isTrue(_ presence: Presence<Bool>) -> Bool {
    switch presence {
    case .missing, .null: return false
    case .value(let value): return value
    }
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
    let schema = schemaRegistryOperation(ObjectSchemaRegistry<capacity>.self)
    let typed = typedObjectOperation(BoundedObject<IoSource, 512, capacity>.self)
    let predicate = predicateOperation(ObjectPredicate<capacity, capacity, capacity, capacity>.self)
    return OperationRecord(
        measurementPoint: capacity,
        byteCapacity: capacity,
        fieldCapacity: capacity,
        nameCapacity: capacity,
        externalIDCapacity: capacity,
        objectInitialization: initialization,
        envelopeInitialization: envelopeInitialization(ObjectEnvelope<capacity, capacity>.self),
        randomizedEditRead: randomizedEditRead(BoundedDynamicObject<capacity, capacity>.self),
        saturationMeasurement: capacity == 1 ? "minimum-object-rejection" : "edit-capacity-failure",
        saturationRejected: saturationResult.rejected,
        unchangedAfterSaturation: saturationResult.unchanged,
        schemaRegistration: schema.registration,
        schemaRegistryCount: schema.count,
        schemaRegistrySaturated: schema.saturated,
        schemaRegistryUnchangedAfterSaturation: schema.unchangedAfterSaturation,
        typedObjectInitialization: typed.initialization,
        typedObjectValueTypePreserved: typed.valueTypePreserved,
        typedObjectByteCapacity: 512,
        typedObjectFieldCapacity: capacity,
        predicateInitialization: predicate.initialization,
        predicateDecodeEvaluateEncode: predicate.decodeEvaluateEncode,
        predicateRoundTrip: predicate.roundTrip
    )
}

private func predicateLayout<let capacity: Int>(_: ObjectPredicate<capacity, capacity, capacity, capacity>.Type) -> PredicateLayoutRecord {
    PredicateLayoutRecord(
        measurementPoint: capacity,
        type: "ObjectPredicate<\(capacity),\(capacity),\(capacity),\(capacity)>",
        size: MemoryLayout<ObjectPredicate<capacity, capacity, capacity, capacity>>.size,
        alignment: MemoryLayout<ObjectPredicate<capacity, capacity, capacity, capacity>>.alignment,
        stride: MemoryLayout<ObjectPredicate<capacity, capacity, capacity, capacity>>.stride,
        nodeCapacity: capacity,
        pathCapacity: capacity,
        literalCapacity: capacity,
        arenaCapacity: capacity
    )
}

private func schemaLayout<let capacity: Int>(_: ObjectSchemaRegistry<capacity>.Type) -> SchemaLayoutRecord {
    SchemaLayoutRecord(
        measurementPoint: capacity,
        type: "ObjectSchemaRegistry<\(capacity)>",
        size: MemoryLayout<ObjectSchemaRegistry<capacity>>.size,
        alignment: MemoryLayout<ObjectSchemaRegistry<capacity>>.alignment,
        stride: MemoryLayout<ObjectSchemaRegistry<capacity>>.stride,
        registryCapacity: capacity
    )
}

private func report() -> ProbeReport {
    ProbeReport(
        measurementPoints: measurementPoints,
        layouts: [
            objectLayout(BoundedDynamicObject<1, 1>.self), envelopeLayout(ObjectEnvelope<1, 1>.self),
            objectLayout(BoundedDynamicObject<16, 16>.self), envelopeLayout(ObjectEnvelope<16, 16>.self),
            objectLayout(BoundedDynamicObject<64, 64>.self), envelopeLayout(ObjectEnvelope<64, 64>.self),
        ],
        schemaLayouts: [
            schemaLayout(ObjectSchemaRegistry<1>.self),
            schemaLayout(ObjectSchemaRegistry<16>.self),
            schemaLayout(ObjectSchemaRegistry<64>.self),
        ],
        predicateLayouts: [
            predicateLayout(ObjectPredicate<1, 1, 1, 1>.self),
            predicateLayout(ObjectPredicate<16, 16, 16, 16>.self),
            predicateLayout(ObjectPredicate<64, 64, 64, 64>.self),
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
        for _ in 0..<iterations { allocationSink &+= UInt64(envelope.name.length) + (isTrue(envelope.isDeactivated) ? 1 : 0) }
    case .schemaRegistryInitialization:
        var registry = ObjectSchemaRegistry<capacity>()
        for _ in 0..<iterations {
            registry = ObjectSchemaRegistry<capacity>()
            try? registry.use(IoSource.self)
            allocationSink &+= UInt64(registry.sealed().count)
        }
    case .typedObjectInitialization:
        for _ in 0..<iterations {
            if let object = try? BoundedObject<IoSource, 512, capacity>(decoding: slice(ioSourceBytes)) {
                allocationSink &+= object.value.valueType.length > 0 ? 1 : 0
            }
        }
    case .typedObjectWarmed:
        guard let object = try? BoundedObject<IoSource, 512, capacity>(decoding: slice(ioSourceBytes)) else { return }
        for _ in 0..<iterations { allocationSink &+= object.value.valueType.length > 0 ? 1 : 0 }
    case .predicateInitialization:
        for _ in 0..<iterations {
            do throws(ObjectError) {
                _ = try ObjectPredicate<capacity, capacity, capacity, capacity>(decoding: slice(predicateBytes))
                allocationSink &+= 1
            } catch {}
        }
    case .predicateWarmed:
        guard let predicate = try? ObjectPredicate<capacity, capacity, capacity, capacity>(decoding: slice(predicateBytes)),
              let object = try? BoundedDynamicObject<capacity, capacity>(decoding: slice("{\"value\":1}")) else { return }
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
        defer { output.deallocate() }
        for _ in 0..<iterations {
            allocationSink &+= predicate.matches(object: object) ? 1 : 0
            var writer = WireWriter(buffer: output, capacity: 128)
            try? predicate.encode(to: &writer)
        }
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
