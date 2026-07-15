# T-027: Advertise async lifecycle blocker

## Status

Blocked for the current slice. The safe parts of T-027 landed:

- `ParsedMQTTMessage` — a value-typed, `Sendable` representation of a parsed MQTT
  `PUBLISH` that carries routing metadata without passing reference-typed
  `CommunicationTopic` across isolation boundaries.
- `AdvertiseEventSnapshot` — a value-typed, `Sendable` snapshot of an Advertise
  event, including a `parsedMQTTMessage:` decoding initializer.
- `CommunicationEventHubKeys.advertise(...)` — internal hub keys used by
  `MQTTNIOClient` to route parsed Advertise snapshots into the `EventHub`.
- `MQTTNIOClient.routeAdvertiseSnapshot(...)` — transport-side routing of parsed
  Advertise snapshots into the async event hub.

The public async Advertise stream API (`observeAdvertiseStream(withCoreType:)`
and `observeAdvertiseStream(withObjectType:)`) was removed from this slice.

## Why the public API was removed

The public API required first/last lifecycle callbacks for the `EventHub`
stream so that MQTT subscriptions would be established when the first async
iterator was created and removed when the last iterator terminated. The
`EventHub` actor requires these callbacks to be `@Sendable`.

`CommunicationManager` is a non-isolated, non-`Sendable` class whose
subscription logic (`subscribe(topic:)` / `unsubscribe(topic:)`) uses a
private `DispatchQueue` for synchronization. Capturing the manager in a
`@Sendable` closure to forward lifecycle callbacks would violate Swift 6 strict
concurrency checking. The only way to satisfy the compiler inside the
`CM+AdvertiseStream.swift` implementation was a production
`@unchecked Sendable` bridge (`AdvertiseStreamLifecycleBridge`), which T-027
explicitly forbids.

No safe workaround exists without changing the architecture, because:

1. `CommunicationManager` owns the topic ref-counting map, the deferred
   subscription set, and the online-state decision for whether to call the
   client. Moving that state to an actor requires either rewriting the legacy
   Rx `subscribe` / `unsubscribe` paths or duplicating the logic in a separate
   coordinator.
2. The legacy Rx paths are synchronous and rely on `DispatchQueue.sync`.
   Calling an actor from them would make them `async`, which is a source- and
   runtime-breaking change to the existing Rx-based observe/publish API that
   T-027 is required to preserve.
3. A separate actor coordinator could own the ref-counting and call the client
   directly, but it would then need to replicate the manager's online-state
   deferral and reconnect replay behavior. The natural source for that state is
   the `EventHub` `communicationState` stream, but wiring that up cleanly would
   pull the coordinator, the client, and the manager into a larger refactor that
   exceeds the T-027 slice.

## What is needed to unblock the public API

The next slice should choose one of these two designs and commit to it fully:

### Option A: Actor-owned subscription coordinator

Introduce a `SubscriptionCoordinator` actor (or similar) that:

- owns the topic ref-count map and the deferred-subscription set,
- observes `CommunicationState` via the `EventHub` state stream to know when
  the client is online,
- invokes `client.subscribe(_:)` / `client.unsubscribe(_:)` directly from its
  own isolation, and
- is used by both the legacy `CommunicationManager.subscribe` /
  `unsubscribe` methods (via `async` / `await` or a minimal synchronous
  wrapper) and the new async stream lifecycle callbacks.

This option requires migrating the manager's subscription state into the
actor and ensuring the legacy Rx paths can still call it without data races.

### Option B: Make `CommunicationManager` actor-safe

Convert `CommunicationManager` to an actor (or a `MainActor`-bound type) and
update all legacy Rx callers to invoke it across the actor boundary. This is
a larger T-039 / T-040-scale change and is only appropriate if the next slice
is explicitly scoped for the manager actor migration.

## Recommended slice boundary

Keep the safe parsed-transport routing and snapshot infrastructure that landed
in T-027. Do not re-introduce `observeAdvertiseStream` until the lifecycle
blocker above is resolved with a design that contains no production
`@unchecked Sendable` types.

The existing Rx-based Advertise observe API (`observeAdvertise` in
`CM+Observe.swift`) continues to work unchanged and is the supported path for
Advertise consumers until the async API is unblocked.
