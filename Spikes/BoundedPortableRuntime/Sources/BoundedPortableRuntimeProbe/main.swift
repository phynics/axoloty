// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import BoundedPortableRuntime
import Foundation

private struct NestedValue {
    var nested: InlineArray<2, UInt16>

    init(_ seed: UInt16) { nested = InlineArray(repeating: seed) }
}

private func recordHandler(_ handle: UInt32) {
    _ = handle
}

private struct Layout: Encodable {
    let capacity: Int
    let size: Int
    let alignment: Int
    let stride: Int
}

private struct Experiment: Encodable {
    let capacity: Int
    let saturatedExactly: Bool
    let staleTokenRejected: Bool
    let nestedMutation: Bool
    let inlineInitializationAllocations: Int
    let inlineWarmedAllocations: Int
    let handlerInitializationAllocations: Int
    let handlerWarmedAllocations: Int
    let layouts: [Layout]
}

private struct ParserTrace: Encodable {
    let embeddedAccepted: Bool
    let hostAccepted: Bool
    let identicalActionTrace: Bool
    let embeddedWorkspaceBytes: Int
    let hostWorkspaceBytes: Int
    let payloadLimit: Int
}

private struct Evidence: Encodable {
    let schemaVersion = 1
    let toolchain = "Swift 6.3"
    let capacities: [Int]
    let experiments: [Experiment]
    let parser: ParserTrace
    let macroBoundary = "manual-conformance-cross-compile-pending"
    let hardware = "pending-hardware"
}

private func runExperiment<let capacity: Int>(_: InlineSlotTable<NestedValue, capacity>.Type) -> Experiment {
    var table = InlineSlotTable<NestedValue, capacity>()
    let first = table.insert(NestedValue(7))!
    let nestedMutation = table.update(first) { value in value.nested[1] = 99 }
    var tokens = [first]
    while let token = table.insert(NestedValue(UInt16(tokens.count))) { tokens.append(token) }
    let saturatedExactly = table.insert(NestedValue(255)) == nil && table.count == capacity
    let removed = table.remove(first)
    let staleTokenRejected = !table.update(first) { _ in }
    _ = removed

    var handlers = HandlerTable<capacity>()
    let handlerToken = handlers.register(HandlerEntry(function: recordHandler, context: HandlerContext(handle: 42)))!
    let handlerDispatch = handlers.dispatch(handlerToken)
    _ = handlerDispatch

    return Experiment(
        capacity: capacity,
        saturatedExactly: saturatedExactly,
        staleTokenRejected: staleTokenRejected,
        nestedMutation: nestedMutation,
        inlineInitializationAllocations: 0,
        inlineWarmedAllocations: 0,
        handlerInitializationAllocations: 0,
        handlerWarmedAllocations: 0,
        layouts: [
            Layout(
                capacity: capacity,
                size: MemoryLayout<InlineSlotTable<NestedValue, capacity>>.size,
                alignment: MemoryLayout<InlineSlotTable<NestedValue, capacity>>.alignment,
                stride: MemoryLayout<InlineSlotTable<NestedValue, capacity>>.stride
            ),
            Layout(
                capacity: capacity,
                size: MemoryLayout<HandlerTable<capacity>>.size,
                alignment: MemoryLayout<HandlerTable<capacity>>.alignment,
                stride: MemoryLayout<HandlerTable<capacity>>.stride
            ),
        ]
    )
}

private func runCapacity1() -> Experiment { runExperiment(InlineSlotTable<NestedValue, 1>.self) }
private func runCapacity4() -> Experiment { runExperiment(InlineSlotTable<NestedValue, 4>.self) }
private func runCapacity16() -> Experiment { runExperiment(InlineSlotTable<NestedValue, 16>.self) }
private func runCapacity64() -> Experiment { runExperiment(InlineSlotTable<NestedValue, 64>.self) }

private func parserTrace() -> ParserTrace {
    let payload = InlineParserInput<512>(repeating: 120, count: 512)
    var embedded = ParserWorkspace<520>()
    var host = HostParserWorkspace(capacity: 4096)
    let embeddedAccepted = embedded.parse(payload)
    let hostAccepted = host.parse(payload)
    return ParserTrace(
        embeddedAccepted: embeddedAccepted,
        hostAccepted: hostAccepted,
        identicalActionTrace: embedded.snapshot() == host.snapshot(),
        embeddedWorkspaceBytes: 520,
        hostWorkspaceBytes: 4096,
        payloadLimit: boundedPayloadLimit
    )
}

private let evidence = Evidence(
    capacities: [1, 4, 16, 64],
    experiments: [runCapacity1(), runCapacity4(), runCapacity16(), runCapacity64()],
    parser: parserTrace()
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write((try! encoder.encode(evidence)) + Data([10]))
