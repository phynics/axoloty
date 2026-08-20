// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

private struct PortableObjectSchema {
    let fieldCount: Int
}

@attached(member, names: named(schema))
private macro AxolotyObject() = #externalMacro(
    module: "BoundedPortableRuntimeMacros",
    type: "AxolotyObjectMacro"
)

@AxolotyObject
private struct EmbeddedMacroObject {}

@_cdecl("bounded_portable_runtime_probe")
func boundedPortableRuntimeProbe() {
    _ = EmbeddedMacroObject.schema
}
