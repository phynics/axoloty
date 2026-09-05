// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import Axoloty
@testable import AxolotyMQTT
import AxolotyProtocol
import AxolotyWire

/// Coaty route synthesis and route classification owned by the MQTT adapter.
///
/// These moved out of the runtime's transport tests when the adapter became
/// its own target: they exercise MQTTBinding, not the transport port.
@Suite("MQTT binding")
struct MQTTBindingTests {
    @Test("binding keeps every Coaty profile route out of external classification")
    func foreignCoatyProfileIsNotExternal() throws {
        let binding = try MQTTBinding(configuration: .init(host: "localhost", port: 1883))
        let route = Array("coaty/3/other-namespace/IOV/00000000-0000-4000-8000-000000000001".utf8)
        let classification = route.withUnsafeBufferPointer { buffer in
            let slice = ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            return binding.classifyRoute(slice)
        }
        #expect(classification == .unrelated)
    }
}
