// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import SwiftSyntax
import SwiftSyntaxMacros

/// Implements the spike-local `@AxolotyObject` member macro.
public struct AxolotyObjectMacro: MemberMacro {
    /// Produces a portable empty schema matching the manual conformance probe.
    ///
    /// - Parameters:
    ///   - node: Macro attribute syntax.
    ///   - declaration: Declaration receiving the synthesized member.
    ///   - protocols: Protocol conformances requested by the expansion.
    ///   - context: Compiler expansion context.
    /// - Returns: The synthesized static schema declaration.
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        ["""
        /// Schema synthesized by `@AxolotyObject`.
        public static let schema = PortableObjectSchema(fieldCount: 0)
        """]
    }
}
