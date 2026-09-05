// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyMQTT

func runAgent() async throws {
    let identity = try RuntimeIdentity(id: .zero, name: "my-agent")
    var builder = try RuntimeBuilder(identity: identity, namespace: "my-app")
    _ = try builder.events(
        matching: .family(.advertise),
        buffering: .fail(capacity: 64)
    )
    let definition = try builder.finish()
    let runtime = AxolotyRuntime(
        definition: definition,
        transport: try MQTTBinding(configuration: .init(host: "localhost", port: 1883))
    )
    try await runtime.run()
}
