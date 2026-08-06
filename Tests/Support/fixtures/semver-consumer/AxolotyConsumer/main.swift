// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty

@MainActor
func compileHostJourney() async throws {
    let configuration = try Configuration.build { builder in
        builder.common = CommonOptions(agentIdentity: ["name": "my-agent"])
        builder.communication = CommunicationOptions(
            namespace: "my-app",
            mqttClientOptions: MQTTClientOptions(host: "localhost", port: 1883),
            shouldAutoStart: false
        )
    }
    let components = Components(controllers: [:], objectTypes: [])
    let container = try Container.resolve(
        components: components,
        configuration: configuration
    )
    guard let manager = container.communicationManager else {
        throw AxolotyError.invalidConfiguration(
            option: "communicationManager",
            reason: "was not initialized"
        )
    }

    try manager.start()
    let stream = try await manager.observeAdvertiseStream(
        withObjectType: Identity.objectType
    )
    manager.publishAdvertise(try AdvertiseEvent.with(object: Identity(name: "my-agent")))
    container.shutdown()

    _ = stream
}
