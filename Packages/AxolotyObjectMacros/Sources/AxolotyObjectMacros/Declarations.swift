// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel

/// Synthesizes a portable object schema and its ``ObjectSchema`` conformance.
@attached(member, names: named(schema), named(init(decoding:)), named(encodeFields(to:)))
@attached(extension, conformances: ObjectSchema)
public macro AxolotyObject(
    objectType: String,
    coreType: String = "CoatyObject"
) = #externalMacro(
    module: "AxolotyObjectMacrosImplementation",
    type: "AxolotyObjectMacro"
)

/// Overrides the wire name of a stored model property.
@attached(peer, names: arbitrary)
public macro WireName(_ name: String) = #externalMacro(
    module: "AxolotyObjectMacrosImplementation",
    type: "WireNameMacro"
)

/// Marks a stored model property as defaulted in the wire schema.
@attached(peer, names: arbitrary)
public macro Default(_ value: Any) = #externalMacro(
    module: "AxolotyObjectMacrosImplementation",
    type: "DefaultMacro"
)
