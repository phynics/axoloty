// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

private enum SchemaDiagnosticID: String {
    case invalidObjectType
    case duplicateWireName
    case reservedWireName
    case tooManyFields
    case unsupportedDeclaration
}

private struct SchemaDiagnostic: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity = .error

    init(_ id: SchemaDiagnosticID, _ message: String) {
        self.message = message
        diagnosticID = MessageID(domain: "AxolotyObject", id: id.rawValue)
    }
}

/// Implements the portable schema member/conformance macro.
public struct AxolotyObjectMacro: MemberMacro, ConformanceMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let typeName = declaration.as(StructDeclSyntax.self)?.name.text
                ?? declaration.as(ClassDeclSyntax.self)?.name.text else {
            context.diagnose(Diagnostic(node: Syntax(declaration), message: SchemaDiagnostic(.unsupportedDeclaration, "@AxolotyObject can only annotate a struct or class")))
            return []
        }

        let arguments = node.arguments?.as(LabeledExprListSyntax.self)
        let objectType = stringArgument(named: "objectType", in: arguments) ?? ""
        let coreType = stringArgument(named: "coreType", in: arguments) ?? "coatyObject"
        if objectType.isEmpty {
            context.diagnose(Diagnostic(node: Syntax(node), message: SchemaDiagnostic(.invalidObjectType, "objectType must be a non-empty string literal")))
        }

        var descriptors: [(name: String, wireName: String, optional: Bool, defaulted: Bool)] = []
        var wireNames: [String] = []
        let reserved: Set<String> = ["objectId", "coreType", "objectType", "name", "externalId", "parentObjectId", "locationId", "isDeactivated"]

        let members: MemberBlockItemListSyntax
        if let structDecl = declaration.as(StructDeclSyntax.self) {
            members = structDecl.memberBlock.members
        } else if let classDecl = declaration.as(ClassDeclSyntax.self) {
            members = classDecl.memberBlock.members
        } else {
            return []
        }

        for member in members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  variable.bindingSpecifier.tokenKind == .keyword(.var),
                  let binding = variable.bindings.first,
                  let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let sourceName = pattern.identifier.text
            let wireName = wireName(for: variable, fallback: sourceName)
            let isOptional = binding.typeAnnotation?.type.description.contains("?") == true
            let hasDefault = variable.attributes?.contains(where: { attribute in
                guard let attribute = attribute.as(AttributeSyntax.self) else { return false }
                return attribute.attributeName.trimmedDescription == "Default"
            }) == true

            if reserved.contains(wireName) {
                context.diagnose(Diagnostic(node: Syntax(variable), message: SchemaDiagnostic(.reservedWireName, "wire field '\(wireName)' is reserved by the object envelope")))
            }
            if wireNames.contains(wireName) {
                context.diagnose(Diagnostic(node: Syntax(variable), message: SchemaDiagnostic(.duplicateWireName, "wire field '\(wireName)' is declared more than once")))
            }
            wireNames.append(wireName)
            descriptors.append((sourceName, wireName, isOptional, hasDefault))
        }

        if descriptors.count > 64 {
            context.diagnose(Diagnostic(node: Syntax(declaration), message: SchemaDiagnostic(.tooManyFields, "portable object schemas support at most 64 fields")))
        }

        var assignments = ""
        for (index, descriptor) in descriptors.prefix(64).enumerated() {
            assignments += "fields[\(index)] = ObjectFieldDescriptor(sourceName: \(literal(descriptor.name)), wireName: \(literal(descriptor.wireName)), index: \(index), isOptional: \(descriptor.optional), hasDefault: \(descriptor.defaulted))\n"
        }
        let generated: DeclSyntax = """
        /// The fixed descriptor synthesized by `@AxolotyObject`.
        public static let schema: PortableObjectSchema<\(raw: typeName)> = {
            var fields = InlineArray<64, ObjectFieldDescriptor>(repeating: .empty)
            \(raw: assignments)
            return PortableObjectSchema<\(raw: typeName)>(objectType: \(literal(objectType)), coreType: \(literal(coreType)), fieldCount: \(descriptors.count), fields: fields)
        }()
        """
        return [generated]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingConformancesOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [TypeSyntax] {
        [TypeSyntax("ObjectSchema")]
    }

    private static func stringArgument(named name: String, in arguments: LabeledExprListSyntax?) -> String? {
        guard let expression = arguments?.first(where: { $0.label?.text == name })?.expression else { return nil }
        guard let literal = expression.as(StringLiteralExprSyntax.self), literal.segments.count == 1,
              let segment = literal.segments.first?.as(StringSegmentSyntax.self) else { return nil }
        return segment.content.text
    }

    private static func wireName(for variable: VariableDeclSyntax, fallback: String) -> String {
        guard let attribute = variable.attributes?.compactMap({ $0.as(AttributeSyntax.self) }).first(where: {
            $0.attributeName.trimmedDescription == "WireName"
        }), let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
              let expression = arguments.first?.expression,
              let literal = expression.as(StringLiteralExprSyntax.self), literal.segments.count == 1,
              let segment = literal.segments.first?.as(StringSegmentSyntax.self) else { return fallback }
        return segment.content.text
    }

    private static func literal(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }
}

/// The marker macro for ``WireName``; all work is performed by the parent
/// ``AxolotyObjectMacro`` while inspecting the declaration.
public struct WireNameMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

/// The marker macro for ``Default``.
public struct DefaultMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}
