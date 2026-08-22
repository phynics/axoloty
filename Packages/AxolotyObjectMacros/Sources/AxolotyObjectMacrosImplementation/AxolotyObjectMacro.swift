// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

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
    case invalidCoreType
    case malformedWireName
    case unsupportedField
    case malformedDefault
    case invalidDefault
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
public struct AxolotyObjectMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(Diagnostic(node: Syntax(declaration), message: SchemaDiagnostic(.unsupportedDeclaration, "@AxolotyObject can only annotate a struct")))
            return []
        }
        let typeName = structDecl.name.text

        let arguments = node.arguments?.as(LabeledExprListSyntax.self)
        let objectType = stringArgument(named: "objectType", in: arguments) ?? ""
        let coreType = stringArgument(named: "coreType", in: arguments) ?? "CoatyObject"
        if arguments?.contains(where: { $0.label?.text == "coreType" }) == true,
           stringArgument(named: "coreType", in: arguments) == nil {
            context.diagnose(Diagnostic(node: Syntax(node), message: SchemaDiagnostic(.invalidCoreType, "coreType must be a string literal")))
        }
        if objectType.isEmpty {
            context.diagnose(Diagnostic(node: Syntax(node), message: SchemaDiagnostic(.invalidObjectType, "objectType must be a non-empty string literal")))
        } else if objectType.utf8.count > 128 {
            context.diagnose(Diagnostic(node: Syntax(node), message: SchemaDiagnostic(.invalidObjectType, "objectType exceeds the bounded 128-byte type limit")))
        } else if !isValidIdentifier(objectType) {
            context.diagnose(Diagnostic(node: Syntax(node), message: SchemaDiagnostic(.invalidObjectType, "objectType must contain only letters, digits, and dots")))
        }
        let validCoreTypes = [
            "CoatyObject", "User", "Annotation", "Task", "IoSource", "IoActor",
            "IoNode", "IoContext", "Identity", "Log", "Location", "Snapshot",
        ]
        if !validCoreTypes.contains(coreType) {
            context.diagnose(Diagnostic(node: Syntax(node), message: SchemaDiagnostic(.invalidCoreType, "coreType '\(coreType)' is not a supported portable core type")))
        }

        var descriptors: [(name: String, type: String, wireName: String, optional: Bool, defaulted: Bool, defaultExpression: String?)] = []
        var wireNames: [String] = []
        let reserved: Set<String> = ["objectId", "coreType", "objectType", "name", "externalId", "parentObjectId", "locationId", "isDeactivated"]

        let members = structDecl.memberBlock.members

        for member in members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard variable.bindings.count == 1,
                  let binding = variable.bindings.first,
                  let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                  variable.bindingSpecifier.tokenKind == .keyword(.var),
                  binding.typeAnnotation != nil,
                  binding.accessorBlock == nil,
                  !variable.modifiers.contains(where: { modifier in
                      modifier.name.tokenKind == .keyword(.static) || modifier.name.tokenKind == .keyword(.class)
                  }) else {
                context.diagnose(Diagnostic(node: Syntax(variable), message: SchemaDiagnostic(.unsupportedField, "schema fields must be one stored, instance `var` with an explicit type")))
                continue
            }
            let sourceName = pattern.identifier.text
            let fieldType = binding.typeAnnotation!.type.trimmedDescription
            let wireAttribute = variable.attributes.compactMap({ $0.as(AttributeSyntax.self) }).first(where: {
                $0.attributeName.trimmedDescription == "WireName"
            })
            let wireName: String
            if let wireAttribute {
                guard let parsed = stringAttributeArgument(wireAttribute) else {
                    context.diagnose(Diagnostic(node: Syntax(wireAttribute), message: SchemaDiagnostic(.malformedWireName, "@WireName requires one string literal argument")))
                    wireName = sourceName
                    continue
                }
                wireName = decodeEscapes(parsed)
            } else {
                wireName = sourceName
            }
            let defaultAttribute = variable.attributes.compactMap({ $0.as(AttributeSyntax.self) }).first(where: {
                $0.attributeName.trimmedDescription == "Default"
            })
            let defaultExpression = defaultAttribute.flatMap(defaultArgument)
            if let defaultAttribute {
                if defaultExpression == nil {
                    context.diagnose(Diagnostic(node: Syntax(defaultAttribute), message: SchemaDiagnostic(.malformedDefault, "@Default requires exactly one value expression")))
                } else if let defaultExpression, !defaultMatches(fieldType: fieldType, expression: defaultExpression) {
                    context.diagnose(Diagnostic(node: Syntax(defaultAttribute), message: SchemaDiagnostic(.invalidDefault, "@Default value does not match field type '\(fieldType)'")))
                }
            }
            let isOptional = fieldType.hasSuffix("?")
            let hasDefault = defaultExpression != nil

            if !isSupportedFieldType(fieldType) {
                context.diagnose(Diagnostic(node: Syntax(variable), message: SchemaDiagnostic(.unsupportedField, "field type '\(fieldType)' is not supported by the bounded schema codec")))
                continue
            }
            if hasDefault && fieldType.hasPrefix("Presence<") {
                context.diagnose(Diagnostic(node: Syntax(defaultAttribute!), message: SchemaDiagnostic(.invalidDefault, "@Default cannot be applied to Presence fields")))
            }

            if reserved.contains(where: { decodeEscapes($0) == wireName }) {
                context.diagnose(Diagnostic(node: Syntax(variable), message: SchemaDiagnostic(.reservedWireName, "wire field '\(wireName)' is reserved by the object envelope")))
            }
            if wireName.utf8.count > 128 {
                context.diagnose(Diagnostic(node: Syntax(variable), message: SchemaDiagnostic(.malformedWireName, "wire field exceeds the bounded 128-byte key limit")))
            }
            if wireNames.contains(where: { decodeEscapes($0) == wireName }) {
                context.diagnose(Diagnostic(node: Syntax(variable), message: SchemaDiagnostic(.duplicateWireName, "wire field '\(wireName)' is declared more than once")))
            }
            wireNames.append(wireName)
            descriptors.append((sourceName, fieldType, wireName, isOptional, hasDefault, defaultExpression))
        }

        if descriptors.count > 24 {
            context.diagnose(Diagnostic(node: Syntax(declaration), message: SchemaDiagnostic(.tooManyFields, "portable object schemas support at most 24 fields")))
            return []
        }

        var assignments = ""
        for (index, descriptor) in descriptors.prefix(24).enumerated() {
            assignments += "fields[\(index)] = ObjectFieldDescriptor(key: ObjectFieldKey(\(literal(descriptor.wireName)))!, index: \(index), flags: \(flags(for: descriptor)))\n"
        }
        let decoderArguments = descriptors.prefix(24).map { descriptor in
            let decode: String
            let isPresence = descriptor.type.hasPrefix("Presence<")
            let decodeType: String
            if isPresence {
                decodeType = String(descriptor.type.dropFirst("Presence<".count).dropLast())
            } else {
                decodeType = descriptor.type.hasSuffix("?") ? String(descriptor.type.dropLast()) : descriptor.type
            }
            if isPresence {
                decode = "try fields.presence(\(literal(descriptor.wireName)), as: \(decodeType).self)"
            } else if let defaultExpression = descriptor.defaultExpression {
                decode = "try fields.decodeIfPresent(\(literal(descriptor.wireName)), as: \(decodeType).self) ?? \(defaultExpression)"
            } else if descriptor.optional {
                decode = "try fields.decodeIfPresent(\(literal(descriptor.wireName)), as: \(decodeType).self)"
            } else {
                decode = "try fields.decode(\(literal(descriptor.wireName)), as: \(descriptor.type).self)"
            }
            return "\(descriptor.name): \(decode)"
        }.joined(separator: ",\n            ")
        let encoderStatements = descriptors.prefix(24).map { descriptor in
            "try encoder.encode(\(descriptor.name), forKey: \(literal(descriptor.wireName)))"
        }.joined(separator: "\n        ")
        let decoderWitness = decoderArguments.isEmpty
            ? "self.init()"
            : "self.init(\n                \(decoderArguments)\n            )"
        let encoderWitness = encoderStatements.isEmpty ? "" : encoderStatements
        let generated: DeclSyntax = """
        /// The fixed descriptor synthesized by `@AxolotyObject`.
        public static let schema: PortableObjectSchema<\(raw: typeName)> = {
            var fields = InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
            \(raw: assignments)
            return PortableObjectSchema<\(raw: typeName)>(objectType: ObjectType(\(raw: literal(objectType)))!, coreType: \(raw: coreExpression(coreType)), fieldCount: \(raw: min(descriptors.count, 24)), fields: fields)
        }()

        /// Decodes the typed fields through the bounded object-field decoder.
        public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
            \(raw: decoderWitness)
        }

        /// Encodes the typed fields through the bounded object-field encoder.
        public borrowing func encodeFields<let editorCapacity: Int>(to encoder: inout ObjectFieldEncoder<editorCapacity>) throws(ObjectEncodingError) {
            \(raw: encoderWitness)
        }
        """
        return [generated]
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let extensionDecl: DeclSyntax = "extension \(type): ObjectSchema {}"
        guard let extensionDecl = extensionDecl.as(ExtensionDeclSyntax.self) else { return [] }
        return [extensionDecl]
    }

    private static func stringArgument(named name: String, in arguments: LabeledExprListSyntax?) -> String? {
        guard let expression = arguments?.first(where: { $0.label?.text == name })?.expression else { return nil }
        guard let literal = expression.as(StringLiteralExprSyntax.self), literal.segments.count == 1,
              let segment = literal.segments.first?.as(StringSegmentSyntax.self) else { return nil }
        return segment.content.text
    }

    private static func stringAttributeArgument(_ attribute: AttributeSyntax) -> String? {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self), arguments.count == 1,
              let expression = arguments.first?.expression,
              let literal = expression.as(StringLiteralExprSyntax.self), literal.segments.count == 1,
              let segment = literal.segments.first?.as(StringSegmentSyntax.self) else { return nil }
        return segment.content.text
    }

    private static func defaultArgument(_ attribute: AttributeSyntax) -> String? {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self), arguments.count == 1 else { return nil }
        return arguments.first?.expression.trimmedDescription
    }

    private static func flags(for descriptor: (name: String, type: String, wireName: String, optional: Bool, defaulted: Bool, defaultExpression: String?)) -> String {
        var values: [String] = []
        if descriptor.optional { values.append(".optional") } else { values.append(".required") }
        if descriptor.defaulted { values.append(".defaulted") }
        if descriptor.type.hasPrefix("Presence<") { values.append(".presence") }
        return values.joined(separator: ", ")
    }

    private static func coreExpression(_ value: String) -> String {
        switch value {
        case "CoatyObject": return ".coatyObject"
        case "User": return ".user"
        case "Annotation": return ".annotation"
        case "Task": return ".task"
        case "IoSource": return ".ioSource"
        case "IoActor": return ".ioActor"
        case "IoNode": return ".ioNode"
        case "IoContext": return ".ioContext"
        case "Identity": return ".identity"
        case "Log": return ".log"
        case "Location": return ".location"
        case "Snapshot": return ".snapshot"
        default: return ".coatyObject"
        }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        for scalar in value.unicodeScalars {
            let valid = (scalar.value >= 48 && scalar.value <= 57) ||
                (scalar.value >= 65 && scalar.value <= 90) ||
                (scalar.value >= 97 && scalar.value <= 122) || scalar.value == 46
            if !valid { return false }
        }
        return true
    }

    private static func decodeEscapes(_ value: String) -> String {
        var result = ""
        var iterator = value.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar.value == 92, let next = iterator.next() else {
                result.unicodeScalars.append(scalar); continue
            }
            switch next.value {
            case 34: result.append("\"")
            case 92: result.append("\\")
            case 110: result.append("\n")
            case 114: result.append("\r")
            case 116: result.append("\t")
            case 117:
                var code = 0
                for _ in 0..<4 { guard let digit = iterator.next(), let value = hexValue(digit.value) else { return value }; code = code * 16 + value }
                if let unicode = UnicodeScalar(code) { result.unicodeScalars.append(unicode) }
            default: result.unicodeScalars.append(next)
            }
        }
        return result
    }

    private static func hexValue(_ value: UInt32) -> Int? {
        if value >= 48 && value <= 57 { return Int(value - 48) }
        if value >= 65 && value <= 70 { return Int(value - 55) }
        if value >= 97 && value <= 102 { return Int(value - 87) }
        return nil
    }

    private static func defaultMatches(fieldType: String, expression: String) -> Bool {
        let type = fieldType.hasSuffix("?") ? String(fieldType.dropLast()) : fieldType
        if expression.hasPrefix("\"") { return false }
        if expression == "true" || expression == "false" { return type == "Bool" }
        if expression == "nil" { return fieldType.hasSuffix("?") }
        if expression.first.map({ $0 == "-" || $0.isNumber }) == true {
            return type == "Int"
        }
        return false
    }

    private static func isSupportedFieldType(_ value: String) -> Bool {
        if value == "Int" || value == "Bool" || value == "ObjectID" { return true }
        if value == "Int?" || value == "Bool?" || value == "ObjectID?" { return true }
        if isBoundedText(value) || isBoundedText(value, optional: true) { return true }
        if value.hasPrefix("Presence<") && value.hasSuffix(">") {
            let wrapped = value.dropFirst("Presence<".count).dropLast()
            return isSupportedFieldType(String(wrapped))
        }
        return false
    }

    private static func isBoundedText(_ value: String, optional: Bool = false) -> Bool {
        let spelling = optional ? String(value.dropLast()) : value
        guard spelling.hasPrefix("BoundedEncodedText<"), spelling.hasSuffix(">") else { return false }
        let capacity = spelling.dropFirst("BoundedEncodedText<".count).dropLast()
        return !capacity.isEmpty && capacity.allSatisfy(\.isNumber)
    }

    private static func literal(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result.append("\\\"")
            case 92: result.append("\\\\")
            case 10: result.append("\\n")
            case 13: result.append("\\r")
            case 9: result.append("\\t")
            default: result.unicodeScalars.append(scalar)
            }
        }
        result.append("\"")
        return result
    }
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
