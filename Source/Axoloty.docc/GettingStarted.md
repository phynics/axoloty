# Getting Started

Add Axoloty to a Swift Package Manager project, configure a container, and
bootstrap a Coaty agent that connects to an MQTT broker.

## Add the package dependency

Add Axoloty to the `dependencies` array in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/phynics/coaty-swift", from: "2.4.0"),
]
```

Then link it into your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Axoloty", package: "coaty-swift"),
    ]),
```

## Configure and start a container

A Coaty agent is bootstrapped by a ``Container``. You configure it with a
``Configuration`` (built from common and communication options) and a
``Components`` registration of your application's controllers and object
types.

This minimal example connects to a broker on `localhost:1883`, starts
communication automatically, and resolves a ready-to-use container:

```swift
import Axoloty

let configuration = try Configuration.build { builder in
    builder.common = CommonOptions(
        agentIdentity: ["name": "my-agent"]
    )
    builder.communication = CommunicationOptions(
        namespace: "my-app",
        mqttClientOptions: MQTTClientOptions(host: "localhost", port: 1883),
        shouldAutoStart: true
    )
}

let components = Components(controllers: [:], objectTypes: [])
let container = Container.resolve(components: components, configuration: configuration)
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

let container = Container.resolve(components: components, configuration: configuration)
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
- Read the [project README](https://github.com/phynics/coaty-swift) for build
  and testing instructions.
