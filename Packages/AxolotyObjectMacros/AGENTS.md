# AxolotyObjectMacros instructions

## Jurisdiction

This guide applies to `Packages/AxolotyObjectMacros/`. The root [`AGENTS.md`](../../AGENTS.md)
rules apply; this guide specializes them for the G3 schema macro package.

## Specialized rules

`AxolotyObjectMacros` contains only SwiftSyntax macro implementation and
diagnostics. It is a build-time ergonomics layer, not a runtime dependency.
The generated conformance, descriptors, and codecs must be behaviorally
equivalent to the corresponding manual `ObjectSchema` conformance and must
not hide unbounded storage or runtime registration.

Pin the SwiftSyntax toolchain version in the package manifest. Diagnose
duplicate wire names, reserved envelope-key collisions, unsupported field
shapes, and invalid defaults at expansion time. Do not use reflection,
Foundation, MQTT/NIO, logging, actors, controllers, lifecycle frameworks,
global mutable state, or process-wide schema registration. Generated source
must not introduce `Array` or `Dictionary` storage into the portable object
model.

This package is not compiled into the Embedded Swift runtime component. The
embedded consumer compiles the equivalent manual conformance or generated
output only when the toolchain explicitly supports it; never check generated
Swift into the repository as a substitute for the source contract.
