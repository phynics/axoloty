# Getting Started

Add Axoloty to a Swift Package Manager project, build an immutable runtime
definition, and connect it to an MQTT broker.

## Add the package dependency

Add the package dependency and link the ``Axoloty`` product:

```swift
dependencies: [
    .package(url: "https://github.com/phynics/axoloty", from: "0.5.1"),
]

.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Axoloty", package: "axoloty"),
    ]
)
```

## Define and start a runtime

The builder is mutable only before ``RuntimeDefinition`` is sealed. Register
bounded event streams and responders before calling `finish()`:

```swift
import Axoloty

func runAgent() async throws {
    let identity = try RuntimeIdentity(id: .zero, name: "my-agent")
    var builder = try RuntimeDefinition.Builder(identity: identity, namespace: "my-app")
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
```

`run()` is single-use. Call ``AxolotyRuntime/stop()`` for graceful shutdown,
or create a new runtime after a terminal failure. Event values and handler
inputs are owned before they cross an asynchronous boundary; raw MQTT topics
are never part of the public runtime API.

## Observe events

Register streams in the definition, retain the returned stream, and consume
owned ``RuntimeEventValue`` values from a task you control. Use the event
context for source identity, correlation, namespace, route classification,
and receipt time.

The same thirteen Coaty Core families are processed by the host and static
profiles. Unknown object types remain dynamic, while malformed known payloads
are rejected at the protocol boundary.

## Static execution

Embedded applications use `AxolotyStaticRuntime` with a fixed capacity and a
caller-owned action sink. Firmware owns only transport, clock, persistence,
and device callbacks; protocol transitions remain in ``AxolotyProtocol``.

## Next steps

Read the project README for build and verification instructions. Typed IO
endpoint and SensorThings APIs are intentionally deferred to G5.
