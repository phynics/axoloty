// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorCore
import Foundation
import Testing

@Suite
struct InspectorDecodeTests {

    // MARK: - Argument parsing

    @Test
    func parsesHexadecimalDiagnosticDecode() {
        let outcome = InspectorArgumentParser().parse(["decode", "--payload", "a1616101"])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.command == .decode(DecodeCommand(source: .hex("a1616101"), render: .diagnostic)))
    }

    @Test
    func parsesBase64JSONDecode() {
        let outcome = InspectorArgumentParser().parse([
            "decode", "--base64", "oWFhAQ==", "--format", "json",
        ])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.command == .decode(DecodeCommand(source: .base64("oWFhAQ=="), render: .json)))
    }

    @Test
    func parsesFileDecode() {
        let outcome = InspectorArgumentParser().parse(["decode", "--file", "/tmp/payload.cbor"])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.command == .decode(DecodeCommand(source: .file("/tmp/payload.cbor"))))
    }

    @Test
    func decodeRequiresAPayloadSource() {
        #expect(InspectorArgumentParser().parse(["decode"]) == .error(.invalidArguments(
            reason: "decode requires one of --payload, --base64, or --file"
        )))
    }

    @Test
    func decodeRejectsMultiplePayloadSources() {
        #expect(InspectorArgumentParser().parse([
            "decode", "--payload", "00", "--file", "/tmp/x",
        ]) == .error(.invalidArguments(reason: "decode accepts only one payload source")))
    }

    @Test
    func decodeRejectsUnknownFormat() {
        #expect(InspectorArgumentParser().parse([
            "decode", "--payload", "00", "--format", "xml",
        ]) == .error(.invalidConfiguration(field: "format", reason: "must be one of: diagnostic, json")))
    }

    @Test
    func parsesExplicitPayloadEncoding() {
        let outcome = InspectorArgumentParser().parse([
            "decode", "--payload", "30", "--encoding", "cbor",
        ])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.command == .decode(
            DecodeCommand(source: .hex("30"), render: .diagnostic, encoding: .cbor)
        ))
    }

    @Test
    func decodeRejectsUnknownEncoding() {
        #expect(InspectorArgumentParser().parse([
            "decode", "--payload", "00", "--encoding", "yaml",
        ]) == .error(.invalidConfiguration(field: "encoding", reason: "must be one of: auto, json, cbor")))
    }

    @Test
    func decodeRejectsUnknownOption() {
        #expect(InspectorArgumentParser().parse([
            "decode", "--payload", "00", "--host", "broker.local",
        ]) == .error(.invalidArguments(reason: "unknown option: --host")))
    }

    @Test
    func decodeRequiresValueForEachOption() {
        #expect(InspectorArgumentParser().parse(["decode", "--payload"]) == .error(.invalidArguments(
            reason: "--payload requires a value"
        )))
        #expect(InspectorArgumentParser().parse(["decode", "--base64"]) == .error(.invalidArguments(
            reason: "--base64 requires a value"
        )))
        #expect(InspectorArgumentParser().parse(["decode", "--file"]) == .error(.invalidArguments(
            reason: "--file requires a value"
        )))
        #expect(InspectorArgumentParser().parse(["decode", "--payload", "00", "--format"]) == .error(
            .invalidArguments(reason: "--format requires a value")
        ))
        #expect(InspectorArgumentParser().parse(["decode", "--payload", "00", "--encoding"]) == .error(
            .invalidArguments(reason: "--encoding requires a value")
        ))
    }

    // MARK: - Rendering

    @Test
    func rendersCBORAsDiagnosticNotation() throws {
        let text = try InspectorDecodeRunner.render(
            DecodeCommand(source: .hex("a26161016162820203"))
        )
        #expect(text == "{\"a\": 1, \"b\": [2, 3]}")
    }

    @Test
    func rendersCBORAsSortedJSON() throws {
        let text = try InspectorDecodeRunner.render(
            DecodeCommand(source: .hex("a2616201616102"), render: .json)
        )
        #expect(text == #"{"a":2,"b":1}"#)
    }

    @Test
    func passesJSONThroughForDiagnosticRendering() throws {
        let text = try InspectorDecodeRunner.render(
            DecodeCommand(source: .hex("7b2261223a317d"))
        )
        #expect(text == #"{"a":1}"#)
    }

    @Test
    func normalizesJSONForJSONRendering() throws {
        let text = try InspectorDecodeRunner.render(
            DecodeCommand(source: .hex("7b2262223a312c2261223a327d"), render: .json)
        )
        #expect(text == #"{"a":2,"b":1}"#)
    }

    @Test
    func rendersAmbiguousPayloadByDeclaredEncoding() throws {
        #expect(try InspectorDecodeRunner.render(DecodeCommand(source: .hex("30"))) == "0")
        #expect(try InspectorDecodeRunner.render(
            DecodeCommand(source: .hex("30"), encoding: .cbor)
        ) == "-17")
    }

    @Test
    func declaredEncodingRejectsAMismatch() {
        #expect(throws: InspectorDecodeError.unsupportedPayload) {
            try InspectorDecodeRunner.render(
                DecodeCommand(source: .hex("a1616101"), encoding: .json)
            )
        }
    }

    @Test
    func decodesBase64Source() throws {
        let text = try InspectorDecodeRunner.render(
            DecodeCommand(source: .base64("oWFhAQ=="))
        )
        #expect(text == "{\"a\": 1}")
    }

    @Test
    func decodesFileSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("axoloty-decode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload.cbor")
        try Data([0xA1, 0x61, 0x61, 0x01]).write(to: file)

        let text = try InspectorDecodeRunner.render(
            DecodeCommand(source: .file(file.path))
        )
        #expect(text == "{\"a\": 1}")
    }

    // MARK: - Failures

    @Test
    func rejectsInvalidHex() {
        #expect(throws: InspectorDecodeError.invalidHex) {
            try InspectorDecodeRunner.render(DecodeCommand(source: .hex("zz")))
        }
        #expect(throws: InspectorDecodeError.invalidHex) {
            try InspectorDecodeRunner.render(DecodeCommand(source: .hex("abc")))
        }
    }

    @Test
    func rejectsInvalidBase64() {
        #expect(throws: InspectorDecodeError.invalidBase64) {
            try InspectorDecodeRunner.render(DecodeCommand(source: .base64("not base64!")))
        }
    }

    @Test
    func rejectsEmptyPayload() {
        #expect(throws: InspectorDecodeError.emptyPayload) {
            try InspectorDecodeRunner.render(DecodeCommand(source: .hex("")))
        }
    }

    @Test
    func rejectsUnknownPayload() {
        #expect(throws: InspectorDecodeError.unsupportedPayload) {
            try InspectorDecodeRunner.render(DecodeCommand(source: .hex("ff")))
        }
    }

    @Test
    func rejectsCBORArrayForJSONRendering() {
        #expect(throws: InspectorDecodeError.notAJSONMap) {
            try InspectorDecodeRunner.render(DecodeCommand(source: .hex("83010203"), render: .json))
        }
    }

    @Test
    func reportsUnreadableFile() {
        #expect(throws: InspectorDecodeError.self) {
            try InspectorDecodeRunner.render(
                DecodeCommand(source: .file("/nonexistent/axoloty/payload.cbor"))
            )
        }
    }
}
