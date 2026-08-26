// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Testing

@Suite("Owned raw JSON boundary")
struct OwnedRawJSONBoundaryTests {
    @Test("malformed JSON is rejected before ownership is published")
    func rejectsMalformedJSON() {
        do {
            _ = try OwnedIoValueWireData(payload: Array(#"{"value":1"#.utf8))
            Issue.record("malformed JSON was accepted")
        } catch let error {
            #expect(error.field != nil)
        }
    }

    @Test("raw fields must satisfy their required JSON shape")
    func rejectsSemanticShapeViolations() {
        do {
            _ = try OwnedUpdateWireData(object: Array("[1]".utf8))
            Issue.record("an array was accepted for an object field")
        } catch let error {
            guard case .typeMismatch = error.reason else {
                Issue.record("unexpected error reason: \(error.reason)")
                return
            }
            #expect(error.field != nil)
        }
    }

    @Test("owned constructors copy their input bytes")
    func ownsInputBytes() throws {
        var source = Array(#"{"value":1}"#.utf8)
        let owned = try OwnedIoValueWireData(payload: source)

        source[0] = 0x5B

        #expect(owned.payload.first == 0x7B)
    }

    @Test("borrowed-to-owned conversion validates field semantics")
    func validatesDuringOwnershipConversion() throws {
        let bytes = Array(#"{"object":[]}"#.utf8)
        let borrowed = try bytes.withUnsafeBufferPointer { buffer in
            try BorrowedWireEvent(
                eventType: .advertise,
                from: WireReader(bytes: buffer.baseAddress!, length: buffer.count)
            )
        }

        do {
            _ = try borrowed.owned()
            Issue.record("an invalid object shape crossed the ownership boundary")
        } catch let error {
            guard case .typeMismatch = error.reason else {
                Issue.record("unexpected error reason: \(error.reason)")
                return
            }
            #expect(error.field != nil)
        }
    }
}
