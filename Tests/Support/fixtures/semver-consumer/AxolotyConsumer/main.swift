// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty

// This consumer depends on the Axoloty product alone and constructs no
// transport. It must compile against both the published release and the
// working tree, so it uses only API common to both -- and it demonstrates the
// boundary the AxolotyMQTT extraction establishes: composing a runtime
// definition requires no MQTT or NIO dependency.
func buildDefinition() throws -> RuntimeDefinition {
    let identity = try RuntimeIdentity(id: .zero, name: "my-agent")
    var builder = try RuntimeBuilder(identity: identity, namespace: "my-app")
    _ = try builder.events(
        matching: .family(.advertise),
        buffering: .fail(capacity: 64)
    )
    return try builder.finish()
}
