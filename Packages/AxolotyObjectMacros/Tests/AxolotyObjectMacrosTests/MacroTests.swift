// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import AxolotyObjectMacros

@Test("schema macro emits a fixed descriptor member")
func schemaMacroExpansion() {
    assertMacroExpansion(
        """
        @AxolotyObject(objectType: "com.example.Reading", coreType: "CoatyObject")
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
                return PortableObjectSchema<Reading>(objectType: "com.example.Reading", coreType: "CoatyObject", fieldCount: 2, fields: fields)
            }()
            public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
                self.init(
                    temperature: try fields.decode("temperature", as: Int.self),
                    alarms: try fields.decodeIfPresent("alarmCodes", as: Int.self)
                )
            }
            public borrowing func encodeFields(to encoder: inout ObjectFieldEncoder) throws(ObjectEncodingError) {
                try encoder.encode(temperature, forKey: "temperature")
                try encoder.encode(alarms, forKey: "alarmCodes")
            }
        }
        extension Reading: ObjectSchema {}
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
                return PortableObjectSchema<Bad>(objectType: "com.example.Bad", coreType: "CoatyObject", fieldCount: 3, fields: fields)
            }()
            public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
                self.init(
                    first: try fields.decode("first", as: Int.self),
                    second: try fields.decode("first", as: Int.self),
                    third: try fields.decode("objectId", as: Int.self)
                )
            }
            public borrowing func encodeFields(to encoder: inout ObjectFieldEncoder) throws(ObjectEncodingError) {
                try encoder.encode(first, forKey: "first")
                try encoder.encode(second, forKey: "first")
                try encoder.encode(third, forKey: "objectId")
            }
        }
        extension Bad: ObjectSchema {}
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

@Test("schema macro rejects unsupported declarations and field shapes")
func schemaMacroShapeDiagnostics() {
    assertMacroExpansion(
        """
        @AxolotyObject(objectType: "com.example.Bad", coreType: "badCore")
        final class Bad {
            var one: Int, two: Int
            static var three: Int = 3
            var computed: Int { 1 }
        }
        """,
        expandedSource: """
        final class Bad {
            var one: Int, two: Int
            static var three: Int = 3
            var computed: Int { 1 }
        }
        """,
        diagnostics: [
            DiagnosticSpec(message: "@AxolotyObject can only annotate a struct", line: 2, column: 1),
        ],
        macros: [
            "AxolotyObject": AxolotyObjectMacro.self,
            "WireName": WireNameMacro.self,
            "Default": DefaultMacro.self,
        ]
    )
}

private let sealedCoreTypeNames = [
    "CoatyObject", "User", "Annotation", "Task", "IoSource", "IoActor",
    "IoNode", "IoContext", "Identity", "Log", "Location", "Snapshot",
]

private func assertValidCoreType(_ coreType: String) {
    assertMacroExpansion(
        """
        @AxolotyObject(objectType: "com.example.CoreProbe", coreType: "\(coreType)")
        struct CoreProbe {}
        """,
        expandedSource: """
        struct CoreProbe {
            public static let schema: PortableObjectSchema<CoreProbe> = {
                var fields = InlineArray<64, ObjectFieldDescriptor>(repeating: .empty)
                return PortableObjectSchema<CoreProbe>(objectType: "com.example.CoreProbe", coreType: "\(coreType)", fieldCount: 0, fields: fields)
            }()
            public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
                self.init()
            }
            public borrowing func encodeFields(to encoder: inout ObjectFieldEncoder) throws(ObjectEncodingError) {
            }
        }
        extension CoreProbe: ObjectSchema {}
        """,
        macros: [
            "AxolotyObject": AxolotyObjectMacro.self,
            "WireName": WireNameMacro.self,
            "Default": DefaultMacro.self,
        ]
    )
}

@Test("schema macro accepts every sealed Coaty core type")
func schemaMacroAcceptsSealedCoreTypes() {
    for coreType in sealedCoreTypeNames {
        assertValidCoreType(coreType)
    }
}

@Test("schema macro rejects invented core types")
func schemaMacroRejectsInventedCoreType() {
    assertMacroExpansion(
        """
        @AxolotyObject(objectType: "com.example.Bad", coreType: "CoatyThing")
        struct Bad {}
        """,
        expandedSource: """
        struct Bad {
            public static let schema: PortableObjectSchema<Bad> = {
                var fields = InlineArray<64, ObjectFieldDescriptor>(repeating: .empty)
                return PortableObjectSchema<Bad>(objectType: "com.example.Bad", coreType: "CoatyThing", fieldCount: 0, fields: fields)
            }()
            public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
                self.init()
            }
            public borrowing func encodeFields(to encoder: inout ObjectFieldEncoder) throws(ObjectEncodingError) {
            }
        }
        extension Bad: ObjectSchema {}
        """,
        diagnostics: [
            DiagnosticSpec(message: "coreType 'CoatyThing' is not a supported portable core type", line: 2, column: 1),
        ],
        macros: [
            "AxolotyObject": AxolotyObjectMacro.self,
            "WireName": WireNameMacro.self,
            "Default": DefaultMacro.self,
        ]
    )
}
