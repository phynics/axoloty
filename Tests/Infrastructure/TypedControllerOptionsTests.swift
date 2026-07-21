// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Testing

@Suite
struct TypedControllerOptionsTests {
    @Test
    func exposesTypedLegacyValues() {
        let context = IoContext(coreType: .IoContext, objectType: IoContext.objectType, objectId: .init(), name: "context")
        let rules = [IoAssociationRule(name: "rule", valueType: nil, condition: { _, _, _, _, _, _ in true })]
        let sensors: [SensorDefinition] = []
        let options = ControllerOptions(extra: [
            "ioContext": context,
            "rules": rules,
            "sensors": sensors,
            "skipSensorAdvertise": true,
            "skipSensorDeadvertise": true,
        ])

        #expect(options.ioContextOption === context)
        #expect(options.ioAssociationRulesOption?.count == 1)
        #expect(options.sensorDefinitionsOption?.isEmpty == true)
        #expect(options.skipsSensorAdvertise)
        #expect(options.skipsSensorDeadvertise)
    }

    @Test
    func rejectsInvalidRequiredIdentityValues() {
        #expect(throws: AxolotyError.self) {
            _ = try AgentIdentityOptionValues(["name": 42])
        }
        #expect(throws: AxolotyError.self) {
            _ = try AgentIdentityOptionValues(["objectId": "not-a-uuid"])
        }
    }
}
