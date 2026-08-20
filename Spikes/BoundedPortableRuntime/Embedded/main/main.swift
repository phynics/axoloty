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
    runCapacity1()
    runCapacity4()
    runCapacity16()
    runCapacity64()
    var workspace = ParserWorkspace<520>()
    _ = workspace.parse(InlineParserInput<512>(repeating: 0, count: 512))
}

@inline(never)
private func runCapacity1() {
    var table = InlineSlotTable<EmbeddedProbeValue, 1>()
    _ = table.insert(EmbeddedProbeValue())
}

@inline(never)
private func runCapacity4() {
    var table = InlineSlotTable<EmbeddedProbeValue, 4>()
    _ = table.insert(EmbeddedProbeValue())
}

@inline(never)
private func runCapacity16() {
    var table = InlineSlotTable<EmbeddedProbeValue, 16>()
    _ = table.insert(EmbeddedProbeValue())
}

@inline(never)
private func runCapacity64() {
    var table = InlineSlotTable<EmbeddedProbeValue, 64>()
    _ = table.insert(EmbeddedProbeValue())
}
