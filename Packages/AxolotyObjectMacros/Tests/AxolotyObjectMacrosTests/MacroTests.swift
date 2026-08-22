// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import AxolotyObjectMacros

@Test("schema macro emits a fixed descriptor member")
func schemaMacroExpansion() {
    assertMacroExpansion(
        """
        @AxolotyObject(objectType: "com.example.Reading", coreType: "coatyObject")
        struct Reading {
            var temperature: Int
            @WireName("alarmCodes") var alarms: Int?
        }
        """,
        expandedSource: """
        struct Reading {
            var temperature: Int
            @WireName("alarmCodes") var alarms: Int?
            public static let schema: PortableObjectSchema<Reading> = {
                var fields = InlineArray<64, ObjectFieldDescriptor>(repeating: .empty)
                fields[0] = ObjectFieldDescriptor(sourceName: "temperature", wireName: "temperature", index: 0, isOptional: false, hasDefault: false)
                fields[1] = ObjectFieldDescriptor(sourceName: "alarms", wireName: "alarmCodes", index: 1, isOptional: true, hasDefault: false)
                return PortableObjectSchema<Reading>(objectType: "com.example.Reading", coreType: "coatyObject", fieldCount: 2, fields: fields)
            }()
        }
        """,
        macros: [
            "AxolotyObject": AxolotyObjectMacro.self,
            "WireName": WireNameMacro.self,
            "Default": DefaultMacro.self,
        ]
    )
}

@Test("schema macro diagnoses duplicate and reserved wire names")
func schemaMacroDiagnostics() {
    assertMacroExpansion(
        """
        @AxolotyObject(objectType: "com.example.Bad")
        struct Bad {
            var first: Int
            @WireName("first") var second: Int
            @WireName("objectId") var third: Int
        }
        """,
        expandedSource: """
        struct Bad {
            var first: Int
            @WireName("first") var second: Int
            @WireName("objectId") var third: Int
            public static let schema: PortableObjectSchema<Bad> = {
                var fields = InlineArray<64, ObjectFieldDescriptor>(repeating: .empty)
                fields[0] = ObjectFieldDescriptor(sourceName: "first", wireName: "first", index: 0, isOptional: false, hasDefault: false)
                fields[1] = ObjectFieldDescriptor(sourceName: "second", wireName: "first", index: 1, isOptional: false, hasDefault: false)
                fields[2] = ObjectFieldDescriptor(sourceName: "third", wireName: "objectId", index: 2, isOptional: false, hasDefault: false)
                return PortableObjectSchema<Bad>(objectType: "com.example.Bad", coreType: "coatyObject", fieldCount: 3, fields: fields)
            }()
        }
        """,
        diagnostics: [
            DiagnosticSpec(message: "wire field 'first' is declared more than once", line: 4, column: 5),
            DiagnosticSpec(message: "wire field 'objectId' is reserved by the object envelope", line: 5, column: 5),
        ],
        macros: [
            "AxolotyObject": AxolotyObjectMacro.self,
            "WireName": WireNameMacro.self,
            "Default": DefaultMacro.self,
        ]
    )
}
