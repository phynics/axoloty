// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import BoundedPortableRuntimeMacroProbe

@Test("macro and manual schema shapes are equivalent")
func schemaParity() {
    #expect(MacroObject.schema == ManualObject.schema)
}
