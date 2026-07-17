# Logging

Filter, tier, and correlate Axoloty's internal diagnostics using `swift-log`.

## Overview

Axoloty's internal diagnostics use per-subsystem [`swift-log`](https://github.com/apple/swift-log)
loggers vended by ``LogManager``. Each logger is labelled `Axoloty.<subsystem>`
(see ``Subsystem``) and writes to `stderr` via a `StreamLogHandler`-backed
implementation.

- Note: Axoloty is a library, so it deliberately never calls
  `LoggingSystem.bootstrap(...)` -- that call is global, may be made at most
  once per process, and is reserved for your application. Because
  ``LogManager``'s loggers need their level to be changeable *after* a call
  site has already stored one (see below), they are **not** routed through
  your app's `LoggingSystem.bootstrap` handler; they always write via their
  own `StreamLogHandler`-backed implementation. Bootstrap your own handler
  for your application's logging as usual -- it simply won't also receive
  Axoloty's internal lines. Use ``LogManager/setLevel(_:for:)`` to control
  what Axoloty writes.

```swift
import Logging

// Your application's own logging, independent of Axoloty's.
LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
```

## Setting verbosity

`CommonOptions.logLevel` sets the default level for every subsystem when the
container resolves:

```swift
let common = CommonOptions(logLevel: .debug)
```

To change verbosity later -- for example to raise it temporarily while
debugging a live issue -- call ``LogManager/setLevel(_:for:)`` directly. It
takes effect immediately, even for loggers a class already vended and stored
in a `private let log = LogManager.logger(...)` property at `init`:

```swift
// Raise every subsystem.
LogManager.setLevel(.trace)

// Raise just one subsystem, e.g. while chasing an MQTT connectivity issue.
LogManager.setLevel(.trace, for: .mqtt)
```

## Filtering by subsystem

Every log line is labelled `Axoloty.<subsystem>` (``Subsystem`` lists
`communication`, `ioRouting`, `runtime`, `sensorThings`, and `mqtt`). Filter
your log viewer or `grep` on that prefix to isolate one area, e.g.
`Axoloty.mqtt` for broker connection/publish/subscribe activity.

## Tiering

| Level | Meaning in Axoloty |
| --- | --- |
| `trace` | Wire-level detail: topics in/out, decoded event shape. |
| `debug` | Control-flow diagnostics: subscription acquire/release, operating-state transitions. |
| `info` | Lifecycle milestones: communication state changes, successful broker connects. |
| `notice`/`warning` | Absorbed failures the transport recovered from on its own (a dropped publish, an ignored malformed inbound event). |
| `error` | An operation failed and the failure was thrown/caught. |
| `critical` | An unrecoverable configuration or bootstrap invariant was violated. |

## Correlating a multi-hop flow

Request/response flows (Discover→Resolve, Query→Retrieve, Update→Complete,
Call→Return) log a `correlationId` at the point the request is published and
at the point a response is published or received -- filter on that id to
follow one logical exchange end to end. A connect/reconnect sequence
(including broker-candidate fallback and `autoReconnect` retries) shares one
`correlationId` across every attempt, logged at each attempt and again at the
eventual online transition. An Associate event has no wire-level correlation
id; its `(ioSourceId, ioActorId)` metadata pair is stable for the
association's lifetime and serves the same purpose for correlating an
Associate with the IoValue traffic it enables.

## Distributed `Log` objects vs. local diagnostics

``Controller/logDebug(message:tags:)`` and its siblings (`logInfo`,
`logWarning`, `logError`, `logFatal`) are a distinct concern: they build a
Coaty `Log` domain object and advertise it over the bus for other agents to
observe, independent of this local, process-level `swift-log` diagnostic
system. Calling one of them also emits a correlated `swift-log` line (through
the `Axoloty.runtime` logger, at the matching level, with the `Log` object's
tags carried as metadata) so both views stay in sync without a second call
site.
