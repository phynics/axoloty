// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyWire
import Testing

/// Regression coverage for the in-place field index introduced for issue
/// #1017. All three reader entry points (default JSON, caller-owned workspace
/// JSON, and CBOR) initialize `WireReader.index` once and fill it through a
/// pointer; they no longer build a local index and copy it into the reader.
/// These tests pin the observable index contents and the compact storage
/// bound so the refactor stays behavior preserving.
@Suite("Wire reader in-place field index")
struct WireReaderInPlaceIndexTests {
    private static let mixedJSON =
        #"{"name":"axoloty","count":7,"ok":true,"off":false,"none":null,"items":[1,2],"nested":{"a":1}}"#

    @Test("The default and workspace JSON initializers fill the same index")
    func jsonInitializersFillTheSameIndex() {
        let payload = Array(Self.mixedJSON.utf8)
        var workspace = HostWireParserWorkspace(capacity: 4096)
        payload.withUnsafeBufferPointer { buffer in
            let defaultReader = WireReader(bytes: buffer.baseAddress!, length: buffer.count)
            let workspaceReader = WireReader(
                bytes: buffer.baseAddress!, length: buffer.count, workspace: &workspace
            )

            #expect(defaultReader.index.rootObject)
            #expect(defaultReader.index.rootObject == workspaceReader.index.rootObject)
            #expect(defaultReader.index.count == 7)
            #expect(defaultReader.index.count == workspaceReader.index.count)

            for position in 0..<defaultReader.index.count {
                #expect(defaultReader.index.slot(position)?.key == workspaceReader.index.slot(position)?.key)
                #expect(defaultReader.index.slot(position)?.value == workspaceReader.index.slot(position)?.value)
                #expect(defaultReader.index.slot(position)?.content == workspaceReader.index.slot(position)?.content)
                #expect(defaultReader.index.slot(position)?.kind == workspaceReader.index.slot(position)?.kind)
            }
        }
    }

    @Test("The CBOR initializer indexes the map in place")
    func cborInitializerIndexesTheMapInPlace() {
        let cbor = cborMap([
            (cborText("name"), cborText("axoloty")),
            (cborText("count"), cborUnsigned(7)),
            (cborText("ok"), [0xF5]),
        ])
        cbor.withUnsafeBufferPointer { buffer in
            let reader = WireReader(cborBytes: buffer.baseAddress!, length: buffer.count)

            #expect(reader.index.failure == nil)
            #expect(reader.index.rootObject)
            #expect(reader.index.count == 3)
            #expect(reader.index.slot(0)?.kind == .string)
            #expect(reader.index.slot(1)?.kind == .number)
            #expect(reader.index.slot(2)?.kind == .trueValue)
            #expect(stringValue(reader, "name") == "axoloty")
            #expect(reader.readInt("count") == 7)
            #expect(reader.readBool("ok") == true)
        }
    }

    @Test("The JSON index accepts exactly the configured field limit")
    func jsonIndexAcceptsExactlyTheConfiguredFieldLimit() {
        let limit = WireBufferConfig.maxIndexedFields
        let json = "{" + (0..<limit).map { "\"k\($0)\":\($0)" }.joined(separator: ",") + "}"
        let bytes = Array(json.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            let reader = WireReader(bytes: buffer.baseAddress!, length: buffer.count)
            #expect(reader.index.failure == nil)
            #expect(reader.index.count == limit)
            #expect(reader.readInt("k0") == 0)
            #expect(reader.readInt("k23") == 23)
        }
    }

    @Test("The CBOR index stops one field past the configured limit")
    func cborIndexStopsOneFieldPastTheConfiguredLimit() {
        let limit = WireBufferConfig.maxIndexedFields
        let atLimit = cborMap((0..<limit).map { (cborText("k\($0)"), cborUnsigned($0)) })
        atLimit.withUnsafeBufferPointer { buffer in
            let reader = WireReader(cborBytes: buffer.baseAddress!, length: buffer.count)
            #expect(reader.index.failure == nil)
            #expect(reader.index.count == limit)
            #expect(reader.readInt("k23") == 23)
        }

        let overLimit = cborMap((0..<(limit + 1)).map { (cborText("k\($0)"), cborUnsigned($0)) })
        overLimit.withUnsafeBufferPointer { buffer in
            let reader = WireReader(cborBytes: buffer.baseAddress!, length: buffer.count)
            guard let failure = reader.index.failure, case .fieldIndexOverflow = failure.reason else {
                Issue.record("Expected fieldIndexOverflow, got \(String(describing: reader.index.failure))")
                return
            }
            #expect(reader.index.count == limit)
        }
    }

    @Test("An in-place index survives a function return")
    func inPlaceIndexSurvivesAFunctionReturn() {
        let payload = Array(#"{"name":"axoloty","count":7}"#.utf8)
        payload.withUnsafeBufferPointer { buffer in
            let reader = makeReader(buffer.baseAddress!, length: buffer.count)
            #expect(reader.index.count == 2)
            #expect(stringValue(reader, "name") == "axoloty")
            #expect(reader.readInt("count") == 7)
        }
    }
}

private func makeReader(_ bytes: UnsafePointer<UInt8>, length: Int) -> WireReader {
    WireReader(bytes: bytes, length: length)
}

private func stringValue(_ reader: WireReader, _ key: StaticString) -> String? {
    guard let slice = reader.readString(key) else { return nil }
    return slice.withBytes { pointer, count in
        String(decoding: UnsafeRawBufferPointer(start: pointer, count: count), as: UTF8.self)
    }
}

private func cborText(_ string: String) -> [UInt8] {
    let content = Array(string.utf8)
    if content.count < 24 { return [0x60 | UInt8(content.count)] + content }
    if content.count <= 0xFF { return [0x78, UInt8(content.count)] + content }
    return [0x79, UInt8((content.count >> 8) & 0xFF), UInt8(content.count & 0xFF)] + content
}

private func cborUnsigned(_ value: Int) -> [UInt8] {
    if value < 24 { return [UInt8(value)] }
    if value <= 0xFF { return [0x18, UInt8(value)] }
    return [0x19, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

private func cborMap(_ pairs: [(key: [UInt8], value: [UInt8])]) -> [UInt8] {
    let header: [UInt8] = pairs.count < 24 ? [0xA0 | UInt8(pairs.count)] : [0xB8, UInt8(pairs.count)]
    return pairs.reduce(header) { $0 + $1.key + $1.value }
}
