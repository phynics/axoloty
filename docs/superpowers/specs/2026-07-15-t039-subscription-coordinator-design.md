# T-039: Communication subscription coordinator integration

## Status

Implemented in the working tree on 2026-07-15; the manager, transport, logging,
object-lifecycle, IO routing, SensorThings, and RxSwift-removal verification
gates pass.

## Problem

T-027 introduced immutable communication-event snapshots, transport routing through
`EventHub`, and an actor-owned `CommunicationSubscriptionCoordinator`. The
coordinator is not yet connected to `CommunicationManager`. The manager still owns
the legacy `subscriptions` reference-count map and `deferredSubscriptions` set under
a private `DispatchQueue`.

Consequently, an `EventHub` stream cannot safely acquire and release MQTT topics in
its `@Sendable` first/last callbacks: those callbacks would have to capture the
non-Sendable `CommunicationManager`. The public async Advertise API remains
unavailable.

## Scope

This slice integrates the existing coordinator as the sole owner of desired and
active MQTT subscription state. It restores public async Advertise observation for
core-type and object-type filters.

The finished modernization does not promise support for legacy Rx observation
callers. No compatibility bridge is retained; all in-repository consumers use
snapshots and owned Swift concurrency tasks.

## Architecture

`CommunicationClient` is `Sendable`, and the existing concrete MQTT client keeps
its established audited conformance. `CommunicationSubscriptionCommandDispatcher`
is an actor that owns the client command boundary. The
`CommunicationSubscriptionCoordinator` owns per-topic desired reference counts,
active subscriptions, and online/offline state. It emits an ordered
`SubscriptionCommand` whenever the physical MQTT client must subscribe or
unsubscribe.

`CommunicationManager` owns the coordinator-facing subscription interface:

1. Its existing connection-state observation forwards online/offline transitions to
   the coordinator.
2. Its async subscription operations acquire and release topics through the
   coordinator rather than mutating local maps.
3. The coordinator command sink delivers `.subscribe` and `.unsubscribe` to the
   `CommunicationClient` through a Sendable-safe command-delivery boundary. It must
   not capture the manager and must not introduce `@unchecked Sendable` in
   production code.
4. Stopping or disposing the manager resets the coordinator so desired topics do not
   survive a manager lifecycle reset.

The legacy `subscriptions` and `deferredSubscriptions` storage is removed. The
existing Rx Advertise APIs are not expanded and are removed once their in-repository
consumers have migrated. Deferred publications are intentionally outside this design
and remain managed by the existing queue.

## Async Advertise API

Add two public methods:

```swift
func observeAdvertiseStream(withCoreType: CoreType) async -> EventStream<AdvertiseEventSnapshot>
func observeAdvertiseStream(withObjectType: String) async throws -> EventStream<AdvertiseEventSnapshot>
```

Each method derives the same namespace-aware MQTT topic as its Rx counterpart and
registers the corresponding existing `CommunicationEventHubKeys.advertise` key.
The stream's first iterator acquires that topic through the coordinator; the last
iterator releases it. The callbacks only capture Sendable state owned by the safe
subscription boundary. The stream uses event buffering and does not replay earlier
Advertise events.

Invalid object types retain the existing `AxolotyError.InvalidArgument` behavior.
The snapshot preserves incoming source ID, routing filter, object snapshot, and
private data; it deliberately does not recreate a mutable `AdvertiseEvent`.

## Lifecycle semantics

| Situation | Required result |
| --- | --- |
| First async iterator for a topic while online | One MQTT subscribe command |
| Additional iterators for that topic | No additional MQTT subscribe |
| First iterator while offline | Topic is desired; no command yet |
| Offline-to-online transition | One subscribe for every desired topic |
| Last iterator ends while online | One MQTT unsubscribe command |
| Last iterator ends while offline | Desired topic is removed; no unsubscribe command |
| Manager stop/dispose | Active topics are released and desired state is cleared |

The coordinator remains the serialization point for these transitions, so reconnect
replay cannot diverge across async consumers.

## Error handling

Subscription commands await the MQTT client's acknowledgement future. Transport
failures are converted to `AxolotyError.RuntimeError` and are surfaced by the
manager readiness operation. Invalid public input is validated before stream
registration and expressed as `AxolotyError.InvalidArgument`.

## Tests

Use Swift Testing and the containerized Makefile targets.

- Extend coordinator tests for manager reset and command ordering if required.
- Add manager-integration tests with a controllable communication client or command
  recorder proving async ref-counting.
- Verify offline acquisition, reconnect replay, final release, and lifecycle reset.
- Add async Advertise tests for core type and object type filtering, first/last
  iterator lifecycle, cancellation cleanup, metadata preservation, and invalid
  object type errors.
- Run the new focused test target first (red/green), then the repository's canonical
  `make test` and `make build` checks.

## Non-goals and follow-up order

The remaining event families and consumers are migrated to async streams/tasks.
RxSwift and the legacy runner dependency are removed; repository audits confirm
no package, source, or test dependency remains.
