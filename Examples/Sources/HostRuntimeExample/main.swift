// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty

@main
struct HostRuntimeExample {
    static func main() throws {
        let identity = try RuntimeIdentity(id: .zero, name: "example-agent")
        var builder = try RuntimeDefinition.Builder(identity: identity, namespace: "example")
        _ = try builder.events(matching: .family(.advertise), buffering: .fail(capacity: 64))
        _ = try builder.finish()
        print("Axoloty host runtime definition is ready")
    }
}
