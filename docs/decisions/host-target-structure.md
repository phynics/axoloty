# Architecture decision: host target structure for 0.2

## Decision

**Keep the host target intact for 0.2.** Do not create optional targets for
individual subsystems (Communication, IO routing, SensorThings).

## Context

Issue #353 requires measurement-backed evidence before splitting the host
target. Five representative release-mode consumers were built and measured:

| Consumer | Stripped size | .text | Dependencies | Dynamic libs |
|---|---|---|---|---|
| AxolotyWireConsumer | 133,832 B (~131 KB) | 65,276 B | 1 (AxolotyWire) | 5 |
| AxolotyConsumer | 11,764,480 B (~11.2 MB) | 6,775,937 B | 18 | 18 |
| CommunicationConsumer | 11,768,576 B (~11.2 MB) | 6,776,097 B | 18 | 18 |
| IoRoutingConsumer | 11,764,480 B (~11.2 MB) | 6,775,953 B | 18 | 18 |
| SensorThingsConsumer | 11,768,576 B (~11.2 MB) | 6,776,161 B | 18 | 18 |

## Analysis

### No incremental benefit from subsystem splitting

All host consumers share the same 18-dependency closure and 18 dynamic
libraries. The stripped-size difference between the minimal host consumer
(`AxolotyConsumer`: 11,764,480 B) and the subsystem consumers is at most
4,096 B (0.035%) — well below the 10% threshold for an optional target.

The host runtime's binary weight is dominated by the shared dependency
closure (MQTTNIO, SwiftNIO, NIOSSL, Foundation, swift-log, ErrorKit,
swift-collections, swift-crypto, swift-system). Individual subsystems
(Communication events, IO routing, SensorThings) contribute negligible
incremental size because they are part of the same module and share the
same transitive dependencies.

### Wire-only consumer is already isolated

`AxolotyWireConsumer` at 131 KB stripped with zero host dependencies
remains the only meaningful isolation boundary. This is already shipped as
a separate product (`AxolotyWire`) and validated by the
`hostDependencyCheck` baseline assertion.

## Conclusion

The measurements do not demonstrate a clear benefit from creating optional
targets for Communication, IO routing, or SensorThings. The 0.2 checkpoint
keeps the host target intact. The wire-only boundary (`AxolotyWire`) is the
single isolation surface.

## Build environment

```
Swift version 6.3.3 (swift-6.3.3-RELEASE)
Target: x86_64-unknown-linux-gnu
Build mode: release
Build flags: -c release -Xswiftc -O -Xswiftc -wmo
```

## Measurement date

2026-07-30, commit 12a8355.
