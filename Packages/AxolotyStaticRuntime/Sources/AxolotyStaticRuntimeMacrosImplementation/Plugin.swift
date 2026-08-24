// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct AxolotyStaticRuntimeMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [StaticIoActorMacro.self]
}
