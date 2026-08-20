// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import SwiftSyntax
import SwiftSyntaxMacros

public struct AxolotyObjectMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        ["public static let schema = PortableObjectSchema(fields: [])"]
    }
}
