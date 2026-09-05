// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import Axoloty
@testable import AxolotyMQTT

@Suite
struct MQTTBindingOperationTimeoutTests {
    @Test("MQTTBindingConfiguration rejects an out-of-range operation timeout")
    func mqttBindingConfigurationRejectsInvalidOperationTimeout() {
        #expect(throws: AxolotyError.self) {
            _ = try MQTTBindingConfiguration(operationTimeoutMS: 0)
        }
        #expect(throws: AxolotyError.self) {
            _ = try MQTTBindingConfiguration(operationTimeoutMS: 120_001)
        }
    }

    @Test("MQTTBindingConfiguration accepts and stores a valid operation timeout")
    func mqttBindingConfigurationAcceptsValidOperationTimeout() throws {
        let configuration = try MQTTBindingConfiguration(operationTimeoutMS: 2_500)
        #expect(configuration.operationTimeoutMS == 2_500)
    }

    @Test("MQTTBindingConfiguration defaults the operation timeout to a bounded value")
    func mqttBindingConfigurationDefaultsOperationTimeout() throws {
        // The point of this field is that acknowledgement waits are bounded by
        // default: an unset bound is what let a vanished broker suspend
        // `reconnect()` indefinitely, so the default must be finite and inside
        // the validated range rather than left to the MQTT library's `nil`.
        let defaulted = try MQTTBindingConfiguration()
        #expect(defaulted.operationTimeoutMS == 10_000)
        #expect(defaulted.operationTimeoutMS > 0)
        #expect(defaulted.operationTimeoutMS <= 120_000)
    }
}
