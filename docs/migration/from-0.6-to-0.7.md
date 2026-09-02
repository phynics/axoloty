# Migrate from 0.6 to 0.7

Axoloty 0.7 separates runtime configuration from the immutable runtime
definition. This is a source-breaking change.

Replace `RuntimeDefinition.Builder` with `RuntimeBuilder` and call
`finish()` to obtain a `RuntimeDefinition`:

```swift
let identity = try RuntimeIdentity(id: agentID, name: "agent")
var builder = try RuntimeBuilder(identity: identity, namespace: "my-app")
_ = try builder.events(matching: .family(.resolve), buffering: .dropOldest(capacity: 64))
let definition = try builder.finish()
let runtime = AxolotyRuntime(definition: definition, transport: transport)
```

The old `seal()`, `SealedRuntimeDefinition`, and mutable registration methods
on `RuntimeDefinition` are removed. Use `capacities:` when supplying custom
limits. First-party package integrations now register bounded runtime modules
with stable internal keys; application code does not need to manage those
keys.

## SPI name mappings

First-party packages compiled against the old component SPI must apply these
source changes:

| 0.6 | 0.7 |
|---|---|
| `RuntimeComponentContext` | `RuntimeModuleContext` |
| `RuntimeComponentRegistration` | `RuntimeModuleRegistration` |
| `registerRuntimeComponent(_:)` | `registerRuntimeModule(_:key:)` |
| `reserveRuntimeComponentCorrelationID()` | `reserveRuntimeModuleCorrelationID()` |
| `RuntimeDefinition(namespace:sourceID:identity:capacities:)` | `RuntimeBuilder(sourceID:namespace:identity:capacities:)`, then `finish()` |
| `SealedRuntimeDefinition` | `RuntimeDefinition` |
| `RuntimeDefinition.Builder` | `RuntimeBuilder` |
| `RuntimeDefinition.register(...)` | `RuntimeBuilder.respond(...)` |
| `RuntimeDefinition.registerEvents(...)` | `RuntimeBuilder.events(...)` |
| `RuntimeDefinition.seal()` | `RuntimeBuilder.finish()` |

The built-in IO routing module uses `axoloty.io-routing`; SensorThings uses one
`axoloty.sensor-things` module. The old
`SensorThingsSourceConfiguration`, `SensorThingsObserverConfiguration`,
`sensorThingsSource(configuration:run:)`, and
`sensorThingsObserver(configuration:receive:)` symbols are removed without
aliases. Use one `builder.sensorThings(limits:_:)` transaction. Register each
source with `configuration.source(sensor:thing:observationChannel:run:)` and
each fixed-Sensor stream with
`configuration.observations(for:channel:buffering:)`. Repeated use is rejected
as a structured runtime error, and a
failed draft discards all handlers, streams, and module reservations created by
that draft.
