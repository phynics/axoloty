// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// ESP-IDF creates an INTERFACE component when no source files are registered.
// The Swift integration applies PRIVATE target options, so keep this concrete
// component target even though AxolotyWire itself is pure Swift.
void axoloty_wire_component_anchor(void) {}
