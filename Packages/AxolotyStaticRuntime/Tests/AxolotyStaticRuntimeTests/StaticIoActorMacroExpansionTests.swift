// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyStaticRuntimeMacrosImplementation
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

private let staticIoMacros: [String: Macro.Type] = [
    "StaticIoActor": StaticIoActorMacro.self,
]

@Test("static IO actor macro rejects non-enum declarations")
func staticIoActorRejectsNonEnum() {
    assertMacroExpansion(
        """
        @StaticIoActor(Value.self)
        struct Handler {}
        """,
        expandedSource: """
        struct Handler {}
        """,
        diagnostics: [
            DiagnosticSpec(message: "@StaticIoActor can only annotate an enum", line: 2, column: 1),
        ],
        macros: staticIoMacros
    )
}

@Test("static IO actor macro rejects generic handlers")
func staticIoActorRejectsGenericEnum() {
    assertMacroExpansion(
        """
        @StaticIoActor(Value.self)
        enum Handler<T> {}
        """,
        expandedSource: """
        enum Handler<T> {}
        """,
        diagnostics: [
            DiagnosticSpec(message: "@StaticIoActor does not support generic enums", line: 2, column: 6),
        ],
        macros: staticIoMacros
    )
}

@Test("static IO actor macro requires a compatible receive method")
func staticIoActorRequiresReceive() {
    assertMacroExpansion(
        """
        @StaticIoActor(Value.self)
        enum Handler {}
        """,
        expandedSource: """
        enum Handler {}
        """,
        diagnostics: [
            DiagnosticSpec(
                message: "@StaticIoActor requires a static receive(context:value:delivery:) method with UInt32, Value, and IoDeliveryContext parameters",
                line: 2,
                column: 6
            ),
        ],
        macros: staticIoMacros
    )
}

@Test("static IO actor macro rejects generated-name collisions")
func staticIoActorRejectsCollision() {
    assertMacroExpansion(
        """
        @StaticIoActor(Value.self)
        enum Handler {
            typealias Value = Int
            static func receive(
                context: UInt32,
                value: borrowing Value,
                delivery: borrowing IoDeliveryContext
            ) {}
        }
        """,
        expandedSource: """
        enum Handler {
            typealias Value = Int
            static func receive(
                context: UInt32,
                value: borrowing Value,
                delivery: borrowing IoDeliveryContext
            ) {}
        }
        """,
        diagnostics: [
            DiagnosticSpec(
                message: "@StaticIoActor cannot generate 'Value' because it already exists",
                line: 3,
                column: 15
            ),
        ],
        macros: staticIoMacros
    )
}

@Test("static IO actor macro rejects enum-case name collisions")
func staticIoActorRejectsEnumCaseCollision() {
    assertMacroExpansion(
        """
        @StaticIoActor(Int.self)
        enum Handler {
            case Value
            static func receive(
                context: UInt32,
                value: borrowing Int,
                delivery: borrowing IoDeliveryContext
            ) {}
        }
        """,
        expandedSource: """
        enum Handler {
            case Value
            static func receive(
                context: UInt32,
                value: borrowing Int,
                delivery: borrowing IoDeliveryContext
            ) {}
        }
        """,
        diagnostics: [
            DiagnosticSpec(
                message: "@StaticIoActor cannot generate 'Value' because it already exists",
                line: 3,
                column: 10
            ),
        ],
        macros: staticIoMacros
    )
}
