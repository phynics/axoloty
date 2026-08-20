// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The schema shape shared by the macro and manual conformance probes.
public struct PortableObjectSchema: Equatable, Sendable {
    /// Schema field names in stable source order.
    public let fields: [String]

    /// Creates a portable schema.
    ///
    /// - Parameter fields: Field names in stable source order.
    public init(fields: [String]) { self.fields = fields }
}

/// Synthesizes the minimal ``PortableObjectSchema`` member used by this probe.
@attached(member, names: named(schema))
public macro AxolotyObject() = #externalMacro(
    module: "BoundedPortableRuntimeMacros",
    type: "AxolotyObjectMacro"
)

/// Host object whose schema is synthesized by ``AxolotyObject()``.
@AxolotyObject
public struct MacroObject {}

/// Equivalent source-level conformance used by the embedded consumer.
public struct ManualObject {
    /// Source-level schema equivalent to the macro expansion.
    public static let schema = PortableObjectSchema(fields: [])

    /// Creates the manual probe object.
    public init() {}
}
