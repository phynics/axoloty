// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Testing
@testable import Axoloty

@Suite("Owned raw JSON error boundary")
struct OwnedRawJSONErrorTests {
    @Test("host-owned construction maps wire validation to AxolotyError")
    func mapsWireValidationFailure() throws {
        let event = try CallEvent.with(operation: "read", parameters: "{")

        do {
            _ = try HostWireAdapter.encodeEvent(event)
            Issue.record("malformed raw parameters were accepted")
        } catch let error as AxolotyError {
            guard case let .caught(cause) = error else {
                Issue.record("unexpected Axoloty error category: \(error)")
                return
            }
            #expect(cause is WireDecodeError)
            #expect(error.userFriendlyMessage == "[AxolotyWire.WireDecodeError: 1] The operation could not be completed. (AxolotyWire.WireDecodeError error 1.)")
        }
    }
}
