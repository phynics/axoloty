// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The schema shape shared by the macro and manual conformance probes.
public struct PortableObjectSchema: Equatable, Sendable {
    public let fields: [String]
    public init(fields: [String]) { self.fields = fields }
}

@attached(member, names: named(schema))
public macro AxolotyObject() = #externalMacro(
    module: "BoundedPortableRuntimeMacros",
    type: "AxolotyObjectMacro"
)

@AxolotyObject
public struct MacroObject {}

/// Equivalent source-level conformance used by the embedded consumer.
public struct ManualObject {
    public static let schema = PortableObjectSchema(fields: [])
    public init() {}
}
