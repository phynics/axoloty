# Getting Started

Add Axoloty to a Swift Package Manager project, configure a container, and
bootstrap a Coaty agent that connects to an MQTT broker.

## Add the package dependency

Add Axoloty to the `dependencies` array in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/phynics/axoloty", from: "0.2.0"),
]
```

Then link it into your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Axoloty", package: "axoloty"),
    ]),
```

## Configure and start a container

A Coaty agent is bootstrapped by a ``Container``. You configure it with a
``Configuration`` (built from common and communication options) and a
``Components`` registration of your application's controllers and object
types.

This minimal example configures a broker on `localhost:1883`, resolves a
container, explicitly starts communication, and then shuts it down. The
function is not invoked by the example, so it can be type-checked without a
broker:

```swift
import Axoloty

@MainActor
func runAgent() async throws {
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
    defer { container.shutdown() }
    guard let manager = container.communicationManager else {
        throw AxolotyError.invalidConfiguration(
            option: "communicationManager",
            reason: "was not initialized"
        )
    }

    let stream = try await manager.observeAdvertiseStream(
        withObjectType: Identity.objectType
    )
    var iterator = stream.makeAsyncIterator()
    try await container.startAndWaitUntilReady()
    manager.publishAdvertise(try AdvertiseEvent.with(object: Identity(name: "my-agent")))

    _ = await iterator.next()
}
```

## Register a controller

Controllers contain your application logic and are resolved by the container.
Subclass ``Controller``, register it under a key, and supply matching
``ControllerOptions``:

```swift
class MyController: Controller {
    override func onCommunicationManagerStarting() {
        // Subscribe to communication events here.
    }
}

let components = Components(
    controllers: ["MyController": MyController.self],
    objectTypes: []
)

let configuration = try Configuration.build { builder in
    builder.common = CommonOptions(agentIdentity: ["name": "my-agent"])
    builder.communication = CommunicationOptions(
        mqttClientOptions: MQTTClientOptions(host: "localhost", port: 1883),
        shouldAutoStart: true
    )
    builder.controllers = ControllerConfig(controllerOptions: [
        "MyController": ControllerOptions(),
    ])
}

let container = try Container.resolve(components: components, configuration: configuration)
```

## Shut down

When the agent should stop, shut down the container to cleanly disconnect from
the broker and dispose of controller resources:

```swift
container.shutdown()
```

## Next steps

- Explore the ``CommunicationEvent`` families (discover, query, channel,
  call/return, etc.) in the `Communication` section.
- See ``MQTTClientOptions`` for TLS, last-will, and broker fallback settings.
- Read the [project README](https://github.com/phynics/axoloty) for build
  and testing instructions.
