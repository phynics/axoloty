// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyObjectModel
import AxolotyWire
@testable import AxolotyProtocol

@Suite("Portable IO value contracts")
struct IoValueContractTests {
    @Test("semantic value types are bounded and metadata-owned")
    func valueTypeRoundTrip() throws {
        let type = try IoValueType("com.example.temperature")
        #expect(type.equals("com.example.temperature"))
        #expect(!type.equals("com.example.other"))
    }

    @Test("dynamic values retain their fixed representation")
    func dynamicRepresentation() throws {
        let literal: StaticString = "{}"
        let bytes = ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount)
        let json = try BoundedJSONValue<512>(copying: bytes)
        let value = DynamicIoValue.json(json)
        #expect(value.representation == .json)
    }

    @Test("JSON output copies bounded payloads")
    func jsonOutput() throws {
        var output = IoJSONOutput()
        try output.write("{\"celsius\":23.4}")
        let value = output.finish()
        value.withBytes { bytes in #expect(bytes.equals("{\"celsius\":23.4}")) }
    }

    @Test("publication policies and receipts are exhaustive")
    func policyReceipts() {
        let policy = IoPublicationPolicy.latest(atMostEveryMS: 250)
        #expect(policy == .latest(atMostEveryMS: 250))
        #expect(IoPublicationReceipt.notAssociated != .published)
    }
}
