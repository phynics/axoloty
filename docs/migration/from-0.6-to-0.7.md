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

`SensorThingsObserverConfiguration.requestTimeoutMS` is removed with its
enclosing type and has no replacement. Discovery and query requests now use a
fixed 5,000 ms bound, the same value the old configuration defaulted to.
Applications that raised or lowered that timeout have no supported way to
change it in 0.7.

Thing-driven observation is configured separately with
`configuration.observations(forSensorsOf:matching:buffering:)`. It returns
bounded catalogue-change and relationship-checked observation streams. The
registry performs exact Thing discovery and a parent-filtered Sensor query;
its observation Channel is the Sensor ID. Fixed-Sensor observation continues
to use the explicitly supplied custom Channel. `RuntimeEventContext` now
includes the copied semantic `channelIdentifier` for Channel events.

## Transport, packaging, and module boundaries

The changes below landed after the 0.7 API was first drafted but before it was
released, so they are part of migrating from 0.6 rather than a later step. They
were developed as [epic #781](https://github.com/phynics/axoloty/issues/781).

## The MQTT binding moved to its own product

`MQTTBinding` and `MQTTBindingConfiguration` now live in `AxolotyMQTT`. The
`Axoloty` target no longer depends on `mqtt-nio` or any SwiftNIO module, so an
application that composes a runtime definition without constructing a transport
compiles and links neither. Measured against a consumer of the `Axoloty`
product alone, the linked binary went from 13.2 MB to 3.9 MB and contains no
`MQTTNIO`, `NIOCore`, or `NIOPosix` symbol.

SwiftPM still *resolves* those packages, because they remain declared in the
repository's root manifest for the adapter's benefit; they are fetched but not
built or linked. Removing them from resolution as well requires `AxolotyMQTT`
to become its own SwiftPM package, which is tracked separately.

Add the product where you construct a transport:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Axoloty", package: "axoloty"),
        .product(name: "AxolotyMQTT", package: "axoloty"),
    ]
)
```

and import it in the file that names the binding:

```swift
import Axoloty
import AxolotyMQTT

let runtime = AxolotyRuntime(
    definition: definition,
    transport: try MQTTBinding(configuration: .init(host: "localhost", port: 1883))
)
```

No symbol changed name, and `MQTTBinding` behavior is unchanged. Files that use
`AxolotyRuntime`, `RuntimeBuilder`, `RuntimeDefinition`, or the typed IO API
without naming a transport need no edit.

## The inspector session takes a transport

`AxolotyInspectorSession.init(configuration:)` became
`init(configuration:transport:)`, where the second argument builds the
transport:

| 0.6 | 0.7 |
|---|---|
| `AxolotyInspectorSession(configuration: config)` | `AxolotyInspectorSession(configuration: config, transport: factory)` |
| `AxolotyMCPServer(host:port:namespace:connectTimeout:)` | the same, plus `transport:` |

The factory has the type
`@Sendable (InspectorConnectionConfiguration) throws -> any AxolotyRuntimeTransport`.
The `axoloty-inspect` and `axoloty-mcp` executables are unchanged in behavior:
they supply an MQTT factory, which is where transport selection now lives.

`InspectorConnectionConfiguration` gains `connectTimeoutMilliseconds`, the
clamped millisecond form a transport accepts.

## The transport port carries a finished route

A custom `AxolotyRuntimeTransport` sees a resolved route rather than a routing
key, and `perform` no longer takes a namespace:

| 0.6 | 0.7 |
|---|---|
| `perform(_ effect: RuntimeTransportEffect, namespace: String)` | `perform(_ effect: RuntimeTransportEffect)` |
| `.publish(OwnedProtocolPublication)` | `.publish(RuntimeOutboundMessage)` |

`RuntimeOutboundMessage` is a `route` and a `payload`. Route synthesis moved
into the runtime as `CoatyRoute`, so an adapter no longer needs Coaty profile
knowledge to address a publication — it only decides how to put bytes on a
wire. Adapters that inspected `publication.routingKey` or
`publication.target` now read the route.

`installSubscriptions(namespace:)` and `removeSubscriptions(namespace:)` keep
their names. MQTT implements them as server-side wildcard subscriptions, which
is a broker capability rather than a concept every carrier shares; both default
to no-ops, so an adapter without the concept simply does not implement them.

## `MQTTExternalIoRoute` is `ExternalIoRoute`

The type validating an exact external IO route lost its carrier prefix, and its
members follow:

| 0.6 | 0.7 |
|---|---|
| `MQTTExternalIoRoute(_ topic: String)` | `ExternalIoRoute(_ route: String)` |
| `RuntimeInboundFrame.profile(topic:payload:nowMS:)` | `.profile(route:payload:nowMS:)` |

The accepted grammar is unchanged: bounded UTF-8, no empty segments, and none
of the characters MQTT reserves for wildcards or quoting. That rule is
deliberately no laxer than the validated transport requires, so a route
accepted here stays publishable if a future carrier permits more.

Diagnostic text and documentation that described "MQTT topic separators" or
"MQTT topic levels" now say "route separators" and "route segments". The
`SensorThingsChannel` identifier is documented as a route segment rather than
an MQTT topic level. No behavior changed.

## The runtime extension surface is package-scoped

`@_spi(AxolotyRuntimeAdapter) import Axoloty` becomes a plain `import Axoloty`.
The declarations a first-party capability product uses to register a runtime
module -- `RuntimeModuleContext`, `RuntimeModuleRegistration`,
`registerRuntimeModule`, `reserveRuntimeModuleCorrelationID`, and the
conformance observation used by trace tests -- are now `package` rather than
`public` behind an SPI.

This is a real narrowing rather than a rename. An SPI is a convention: any
package could write the `@_spi` import and get the full surface. `package`
access is enforced by the compiler, so the surface is reachable only from
targets inside this package. Code outside it that imported the SPI to register
a runtime module no longer compiles, and there is no supported replacement --
first-party module registration is the intended audience.

Nothing else changed. `AxolotyIoRouting` and `AxolotySensorThings` use the same
declarations under the same names.

`AxolotyProtocol` keeps its `AxolotyRuntimeAdapter` SPI. `AxolotyStaticRuntime`
consumes it and is compiled for Embedded Swift through CMake components that
pass no `-package-name`, so `package` would not cross that boundary.

## SensorThings schemas moved to `AxolotySensorThingsModel`

The SensorThings schemas and JSON shaping are now their own product, which
depends only on the portable object model. A consumer that encodes or decodes
SensorThings values no longer pulls in the runtime.

```swift
.product(name: "AxolotySensorThingsModel", package: "axoloty"),
```

```swift
import AxolotySensorThings       // registration, sources, the registry
import AxolotySensorThingsModel  // Thing, Sensor, Observation, JSON values
```

No symbol changed name or behavior. Code that only registers SensorThings
workflows needs no edit; code that names a schema type adds the second import.

## MQTT remains the default and validated transport

Nothing about the wire format, the sealed `coaty/3` profile, or broker
interoperability changed. MQTT is the transport Axoloty validates against live
CoatyJS and on hardware; the split makes it a replaceable adapter rather than
part of the runtime's definition.
