// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct BoundedPortableRuntimeMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [AxolotyObjectMacro.self]
}
