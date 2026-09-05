# Migrate from 0.7 to 0.8

Axoloty 0.8 moves the MQTT transport out of the runtime. This is a
source-breaking change for applications that construct a transport.

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

| 0.7 | 0.8 |
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

| 0.7 | 0.8 |
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

| 0.7 | 0.8 |
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
