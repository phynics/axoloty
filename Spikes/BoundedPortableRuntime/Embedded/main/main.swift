// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

private struct EmbeddedProbeValue {
    var bytes: InlineArray<2, UInt8> = InlineArray(repeating: 0)
}

private struct PortableObjectSchema {
    let fieldCount: Int
}

private struct ManualPortableObject {
    static let schema = PortableObjectSchema(fieldCount: 0)
}

@_cdecl("bounded_portable_runtime_probe")
func boundedPortableRuntimeProbe() {
    _ = ManualPortableObject.schema
    var workspace = ParserWorkspace<520>()
    _ = workspace.parse(InlineParserInput<512>(repeating: 0, count: 512))
    #if G1_CAPACITY_1
    runCandidate(InlineSlotTable<EmbeddedProbeValue, 1>.self, reportedCapacity: 1)
    #elseif G1_CAPACITY_4
    runCandidate(InlineSlotTable<EmbeddedProbeValue, 4>.self, reportedCapacity: 4)
    #elseif G1_CAPACITY_16
    runCandidate(InlineSlotTable<EmbeddedProbeValue, 16>.self, reportedCapacity: 16)
    #elseif G1_CAPACITY_64
    runCandidate(InlineSlotTable<EmbeddedProbeValue, 64>.self, reportedCapacity: 64)
    #endif
}

private func embeddedHandler(_ handle: UInt32) { _ = handle }

@inline(never)
private func runCandidate<let capacity: Int>(
    _: InlineSlotTable<EmbeddedProbeValue, capacity>.Type,
    reportedCapacity: UInt32
) {
    let payload = InlineParserInput<512>(repeating: 7, count: 512)
    let initializationHeapBefore = g1_free_internal_heap()
    let initializationTraceStarted = g1_heap_trace_begin() != 0
    var table = InlineSlotTable<EmbeddedProbeValue, capacity>()
    let token = table.insert(EmbeddedProbeValue())!
    var handlers = HandlerTable<capacity>()
    let handlerToken = handlers.register(
        HandlerEntry(function: embeddedHandler, context: HandlerContext(handle: 1))
    )!
    var workspace = ParserWorkspace<520>()
    _ = workspace.parse(payload)
    let initializationAllocations = initializationTraceStarted ? g1_heap_trace_end() : UInt32.max
    let initializationHeapAfter = g1_free_internal_heap()

    _ = table.update(token) { $0.bytes[0] &+= 1 }
    _ = handlers.dispatch(handlerToken)
    _ = workspace.parse(payload)
    let steadyHeapBefore = g1_free_internal_heap()
    let steadyTraceStarted = g1_heap_trace_begin() != 0
    let samples = 30
    let operationsPerSample: UInt32 = 4_000
    var rateSamples = InlineArray<30, UInt32>(repeating: 0)
    var elapsed: UInt32 = 0
    for sample in 0..<samples {
        let sampleStart = g1_time_microseconds()
        for _ in 0..<operationsPerSample {
            _ = table.update(token) { $0.bytes[0] &+= 1 }
            _ = handlers.dispatch(handlerToken)
            _ = workspace.parse(payload)
        }
        let sampleElapsed = g1_time_microseconds() &- sampleStart
        elapsed &+= sampleElapsed
        rateSamples[sample] = sampleElapsed == 0
            ? 0
            : operationsPerSample &* 1_000_000 / sampleElapsed
    }
    let operations = operationsPerSample &* UInt32(samples)
    let steadyAllocations = steadyTraceStarted ? g1_heap_trace_end() : UInt32.max
    let steadyHeapAfter = g1_free_internal_heap()
    let sustainedRate = elapsed == 0 ? 0 : operations &* 1_000_000 / elapsed

    g1_print("{\"schemaVersion\":1,\"evidenceKind\":\"g1-device-run\",\"capacity\":")
    g1_print_uint("", reportedCapacity)
    g1_print(",\"initializationAllocations\":")
    g1_print_uint("", initializationAllocations)
    g1_print(",\"steadyStateAllocations\":")
    g1_print_uint("", steadyAllocations)
    g1_print(",\"initializationHeapBefore\":")
    g1_print_uint("", initializationHeapBefore)
    g1_print(",\"initializationHeapAfter\":")
    g1_print_uint("", initializationHeapAfter)
    g1_print(",\"steadyStateHeapBefore\":")
    g1_print_uint("", steadyHeapBefore)
    g1_print(",\"steadyStateHeapAfter\":")
    g1_print_uint("", steadyHeapAfter)
    g1_print(",\"minimumFreeInternalHeap\":")
    g1_print_uint("", g1_min_free_internal_heap())
    g1_print(",\"largestInternalBlock\":")
    g1_print_uint("", g1_largest_internal_block())
    g1_print(",\"mainStackHighWater\":")
    g1_print_uint("", g1_main_stack_high_water())
    g1_print(",\"mainStackSize\":")
    g1_print_uint("", g1_main_stack_size())
    g1_print(",\"resetReason\":")
    g1_print_uint("", g1_reset_reason())
    g1_print(",\"boardRevision\":")
    g1_print_uint("", g1_board_revision())
    g1_print(",\"flashBytes\":")
    g1_print_uint("", g1_flash_size())
    g1_print(",\"operations\":")
    g1_print_uint("", operations)
    g1_print(",\"elapsedMicroseconds\":")
    g1_print_uint("", elapsed)
    g1_print(",\"sustainedRatePerSecond\":")
    g1_print_uint("", sustainedRate)
    g1_print(",\"rateSamplesPerSecond\":[")
    for sample in 0..<samples {
        if sample != 0 { g1_print(",") }
        g1_print_uint("", rateSamples[sample])
    }
    g1_print("]")
    g1_print(",\"inlineLayout\":{\"size\":")
    g1_print_uint("", UInt32(MemoryLayout<InlineSlotTable<EmbeddedProbeValue, capacity>>.size))
    g1_print(",\"alignment\":")
    g1_print_uint("", UInt32(MemoryLayout<InlineSlotTable<EmbeddedProbeValue, capacity>>.alignment))
    g1_print(",\"stride\":")
    g1_print_uint("", UInt32(MemoryLayout<InlineSlotTable<EmbeddedProbeValue, capacity>>.stride))
    g1_print("},\"handlerLayout\":{\"size\":")
    g1_print_uint("", UInt32(MemoryLayout<HandlerTable<capacity>>.size))
    g1_print(",\"alignment\":")
    g1_print_uint("", UInt32(MemoryLayout<HandlerTable<capacity>>.alignment))
    g1_print(",\"stride\":")
    g1_print_uint("", UInt32(MemoryLayout<HandlerTable<capacity>>.stride))
    g1_print("}}\n")
}
