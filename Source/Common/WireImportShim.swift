// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Re-exports the wire codec module onto `Axoloty` so downstream clients that
/// historically reached wire types through `import Axoloty` keep compiling
/// after the `AxolotyWire` extraction (#290).
///
/// The `@_exported` attribute re-exports ``AxolotyWire``'s public symbols as if
/// they were declared in `Axoloty` itself, preserving the pre-extraction
/// import surface without duplicating any type or codec behavior: both
/// products refer to the same implementation in ``AxolotyWire``.
///
/// Removing this shim is a source-breaking change for clients that import only
/// `Axoloty`. The regression is locked in by `AxolotyWireImportSurfaceTests`.
@_exported import AxolotyWire
