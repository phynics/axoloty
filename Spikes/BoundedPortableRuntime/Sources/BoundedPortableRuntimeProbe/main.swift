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
    let macroBoundary = "measured-by-embedded-check"
    let hardware = "pending-hardware"
}

private enum AllocationCase: String {
    case inlineInitialization = "inline-initialization"
    case inlineWarmed = "inline-warmed"
    case handlerInitialization = "handler-initialization"
    case handlerWarmed = "handler-warmed"
}

nonisolated(unsafe) private var allocationSink: UInt64 = 0

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

@inline(never)
private func allocationRun<let capacity: Int>(
    _: InlineSlotTable<NestedValue, capacity>.Type,
    allocationCase: AllocationCase,
    iterations: Int
) {
    switch allocationCase {
    case .inlineInitialization:
        for index in 0..<iterations {
            let table = InlineSlotTable<NestedValue, capacity>()
            allocationSink &+= UInt64(table.count + index)
        }
    case .inlineWarmed:
        var table = InlineSlotTable<NestedValue, capacity>()
        let token = table.insert(NestedValue(1))!
        for _ in 0..<iterations {
            _ = table.update(token) { $0.nested[0] &+= 1 }
        }
        allocationSink &+= UInt64(table.count)
    case .handlerInitialization:
        for index in 0..<iterations {
            var handlers = HandlerTable<capacity>()
            allocationSink &+= UInt64(index)
            allocationSink &+= UInt64(handlers.register(
                HandlerEntry(function: recordHandler, context: HandlerContext(handle: UInt32(index)))
            ) ?? 0)
        }
    case .handlerWarmed:
        var handlers = HandlerTable<capacity>()
        let token = handlers.register(
            HandlerEntry(function: recordHandler, context: HandlerContext(handle: 42))
        )!
        for _ in 0..<iterations { _ = handlers.dispatch(token) }
        allocationSink &+= token
    }
}

private func runAllocationCase(_ allocationCase: AllocationCase, capacity: Int, iterations: Int) {
    switch capacity {
    case 1: allocationRun(InlineSlotTable<NestedValue, 1>.self, allocationCase: allocationCase, iterations: iterations)
    case 4: allocationRun(InlineSlotTable<NestedValue, 4>.self, allocationCase: allocationCase, iterations: iterations)
    case 16: allocationRun(InlineSlotTable<NestedValue, 16>.self, allocationCase: allocationCase, iterations: iterations)
    case 64: allocationRun(InlineSlotTable<NestedValue, 64>.self, allocationCase: allocationCase, iterations: iterations)
    default: fatalError("unsupported capacity")
    }
    print(allocationSink)
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

if let caseIndex = CommandLine.arguments.firstIndex(of: "--allocation-case") {
    let requestedCase = AllocationCase(rawValue: CommandLine.arguments[caseIndex + 1])!
    let capacityIndex = CommandLine.arguments.firstIndex(of: "--capacity")!
    let iterationsIndex = CommandLine.arguments.firstIndex(of: "--iterations")!
    runAllocationCase(
        requestedCase,
        capacity: Int(CommandLine.arguments[capacityIndex + 1])!,
        iterations: Int(CommandLine.arguments[iterationsIndex + 1])!
    )
} else {
    let evidence = Evidence(
        capacities: [1, 4, 16, 64],
        experiments: [runCapacity1(), runCapacity4(), runCapacity16(), runCapacity64()],
        parser: parserTrace()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write((try! encoder.encode(evidence)) + Data([10]))
}
