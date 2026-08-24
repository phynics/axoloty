// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Generates a concrete C-convention IO actor trampoline and conformance.
public struct StaticIoActorMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let details = validate(node: node, declaration: declaration, context: context) else {
            return []
        }
        return [DeclSyntax(stringLiteral: """
        /// Application value decoded by the generated static IO trampoline.
        public typealias Value = \(details.valueType)

        /// Concrete statically noncapturing handler entry.
        public static var staticIoHandlerEntry: StaticIoHandlerEntry {
            StaticIoHandlerEntry(function: {
                context,
                payload, payloadLength,
                representation,
                sourceID, actorID,
                receivedAtMS, associationGeneration, routeKind in
                guard let value: Value = StaticIoHandlerEntry.decode(
                    Value.self,
                    payload: payload,
                    payloadLength: payloadLength,
                    representationRawValue: representation
                ), let delivery = StaticIoHandlerEntry.deliveryContext(
                    sourceID: sourceID,
                    actorID: actorID,
                    receivedAtMS: receivedAtMS,
                    associationGeneration: associationGeneration,
                    routeKindRawValue: routeKind
                ) else { return }
                \(details.handlerName).receive(
                    context: context,
                    value: value,
                    delivery: delivery
                )
            })
        }
        """)]
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard validate(
            node: node,
            declaration: declaration,
            context: context,
            diagnose: false
        ) != nil else {
            return []
        }
        let generated: DeclSyntax = "extension \(type): StaticIoActorHandler {}"
        return generated.as(ExtensionDeclSyntax.self).map { [$0] } ?? []
    }

    private static func validate(
        node: AttributeSyntax,
        declaration: some DeclGroupSyntax,
        context: some MacroExpansionContext,
        diagnose: Bool = true
    ) -> (handlerName: String, valueType: String)? {
        guard let enumDeclaration = declaration.as(EnumDeclSyntax.self) else {
            if diagnose { context.diagnose(Diagnostic(
                node: Syntax(declaration),
                message: StaticIoActorDiagnostic(
                    id: "declaration",
                    message: "@StaticIoActor can only annotate an enum"
                )
            )) }
            return nil
        }
        guard enumDeclaration.genericParameterClause == nil else {
            if diagnose { context.diagnose(Diagnostic(
                node: Syntax(enumDeclaration.name),
                message: StaticIoActorDiagnostic(
                    id: "generic",
                    message: "@StaticIoActor does not support generic enums"
                )
            )) }
            return nil
        }
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
              arguments.count == 1,
              let argument = arguments.first else {
            if diagnose { context.diagnose(Diagnostic(
                node: Syntax(node),
                message: StaticIoActorDiagnostic(
                    id: "value-type",
                    message: "@StaticIoActor requires one concrete value type"
                )
            )) }
            return nil
        }
        let spelling = argument.expression.trimmedDescription
        guard spelling.hasSuffix(".self"), spelling.count > 5 else {
            if diagnose { context.diagnose(Diagnostic(
                node: Syntax(argument.expression),
                message: StaticIoActorDiagnostic(
                    id: "value-type",
                    message: "@StaticIoActor requires a concrete '.self' value type"
                )
            )) }
            return nil
        }
        let valueType = String(spelling.dropLast(5))
        let generatedNames: Set<String> = ["Value", "staticIoHandlerEntry"]
        for member in enumDeclaration.memberBlock.members {
            if let collision = generatedNameCollision(
                in: member.decl,
                generatedNames: generatedNames
            ) {
                if diagnose { context.diagnose(Diagnostic(
                    node: Syntax(collision),
                    message: StaticIoActorDiagnostic(
                        id: "collision",
                        message: "@StaticIoActor cannot generate '\(collision.text)' because it already exists"
                    )
                )) }
                return nil
            }
        }
        guard hasCompatibleReceive(in: enumDeclaration, valueType: valueType) else {
            if diagnose { context.diagnose(Diagnostic(
                node: Syntax(enumDeclaration.name),
                message: StaticIoActorDiagnostic(
                    id: "receive",
                    message: "@StaticIoActor requires a static receive(context:value:delivery:) method with UInt32, \(valueType), and IoDeliveryContext parameters"
                )
            )) }
            return nil
        }
        return (enumDeclaration.name.text, valueType)
    }

    private static func generatedNameCollision(
        in declaration: DeclSyntax,
        generatedNames: Set<String>
    ) -> TokenSyntax? {
        if let variable = declaration.as(VariableDeclSyntax.self) {
            for binding in variable.bindings {
                if let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                   generatedNames.contains(identifier.identifier.text) {
                    return identifier.identifier
                }
            }
        }
        if let enumCase = declaration.as(EnumCaseDeclSyntax.self) {
            return enumCase.elements.lazy.map(\.name).first {
                generatedNames.contains($0.text)
            }
        }
        let names: [TokenSyntax?] = [
            declaration.as(TypeAliasDeclSyntax.self)?.name,
            declaration.as(FunctionDeclSyntax.self)?.name,
            declaration.as(StructDeclSyntax.self)?.name,
            declaration.as(ClassDeclSyntax.self)?.name,
            declaration.as(EnumDeclSyntax.self)?.name,
            declaration.as(ActorDeclSyntax.self)?.name,
            declaration.as(ProtocolDeclSyntax.self)?.name,
            declaration.as(MacroDeclSyntax.self)?.name,
        ]
        return names.compactMap { $0 }.first {
            generatedNames.contains($0.text)
        }
    }

    private static func hasCompatibleReceive(
        in declaration: EnumDeclSyntax,
        valueType: String
    ) -> Bool {
        for member in declaration.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                  function.name.text == "receive",
                  function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }),
                  function.signature.parameterClause.parameters.count == 3 else {
                continue
            }
            let parameters = Array(function.signature.parameterClause.parameters)
            guard parameters[0].firstName.text == "context",
                  parameters[1].firstName.text == "value",
                  parameters[2].firstName.text == "delivery" else {
                continue
            }
            let contextType = normalized(parameters[0].type.trimmedDescription)
            let receivedValueType = normalized(parameters[1].type.trimmedDescription)
            let deliveryType = normalized(parameters[2].type.trimmedDescription)
            if contextType == "UInt32", receivedValueType == valueType,
               deliveryType == "IoDeliveryContext" || deliveryType.hasSuffix(".IoDeliveryContext") {
                return true
            }
        }
        return false
    }

    private static func normalized(_ type: String) -> String {
        let words = type.split(separator: " ")
        if words.first == "borrowing" || words.first == "consuming" {
            return words.dropFirst().joined(separator: " ")
        }
        return type
    }
}

private struct StaticIoActorDiagnostic: DiagnosticMessage {
    let id: String
    let message: String
    var diagnosticID: MessageID { MessageID(domain: "AxolotyStaticRuntime.StaticIoActor", id: id) }
    let severity: DiagnosticSeverity = .error
}
