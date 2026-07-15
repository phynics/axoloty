# T-039 Subscription Coordinator Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the actor-owned coordinator the single owner of MQTT topic lifetimes and expose safe async Advertise snapshot streams.

**Architecture:** A new actor owns delivery of `SubscriptionCommand` values to the synchronous communication client. `CommunicationManager` owns a coordinator configured with that actor, forwards client connection state to it, and delegates its remaining internal topic helpers to it. Public Advertise streams register existing transport-routed hub keys and capture only the coordinator in lifecycle callbacks.

**Tech Stack:** Swift 6.3, Swift concurrency, Swift Testing, EventHub, mqtt-nio. RxSwift is removed.

## Global Constraints

- Use the root Makefile only; never invoke host-native `swift` commands.
- New Swift source needs the repository copyright header and DocC comments on public declarations.
- Do not add production `@unchecked Sendable` types or capture `CommunicationManager`/`CommunicationClient` in a `@Sendable` closure.
- Preserve deferred publication behavior; only subscription ownership changes.
- Do not add an Rx compatibility API. Existing Rx Advertise methods are temporary implementation dependencies and must not gain new callers.
- The sandbox currently makes `.git` read-only. Run commits only after Git writes are available.

---

## File Structure

- Create `Source/Communication/Manager/CommunicationSubscriptionCommandDispatcher.swift`: actor-isolated delivery of client subscribe/unsubscribe calls.
- Modify `Source/Communication/Manager/CommunicationManager.swift`: construct the dispatcher/coordinator, mirror connection state, and remove manager-owned subscription maps.
- Create `Source/Communication/Manager/CM+AdvertiseStream.swift`: public snapshot streams and namespace-aware topic/key selection.
- Modify `Makefile`: a containerized communication-focused Swift Testing target.
- Modify `Tests/Communication/CommunicationSubscriptionCoordinatorTests.swift`: dispatcher coverage.
- Modify `Tests/Communication/EventHubTransportTests.swift`: manager integration and stream lifecycle coverage.

### Task 1: Isolate subscription command delivery

**Files:**
- Create: `Source/Communication/Manager/CommunicationSubscriptionCommandDispatcher.swift`
- Modify: `Makefile`
- Modify: `Tests/Communication/CommunicationSubscriptionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `SubscriptionCommand`, `CommunicationClient`.
- Produces: `CommunicationSubscriptionCommandDispatcher.deliver(_:) async`.

- [ ] **Step 1: Add the focused Makefile target and write the failing test**

Add `test-communication` to `.PHONY` and a target that runs the development
container's `swift test --filter 'CommunicationSubscriptionCoordinatorTests|EventHubTransportTests'`.

```swift
@Test func dispatcherForwardsCommandsInOrder() async {
    let client = RecordingCommunicationClient()
    let dispatcher = CommunicationSubscriptionCommandDispatcher(client: client)
    await dispatcher.deliver(.subscribe("first"))
    await dispatcher.deliver(.unsubscribe("first"))
    #expect(client.commands == [.subscribe("first"), .unsubscribe("first")])
}
```

- [ ] **Step 2: Run it and verify red**

Run: `make test-communication`

Expected: compile failure because `CommunicationSubscriptionCommandDispatcher` does not exist.

- [ ] **Step 3: Implement the minimal actor**

```swift
actor CommunicationSubscriptionCommandDispatcher {
    private let client: CommunicationClient
    init(client: CommunicationClient) { self.client = client }
    func deliver(_ command: SubscriptionCommand) {
        switch command {
        case .subscribe(let topic): client.subscribe(topic)
        case .unsubscribe(let topic): client.unsubscribe(topic)
        }
    }
}
```

If strict concurrency rejects transfer of the client into the actor, introduce an explicit isolated adapter at the client boundary. Do not use `@preconcurrency` or `@unchecked Sendable` to silence it.

- [ ] **Step 4: Verify green**

Run: `make test-communication`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Makefile Source/Communication/Manager/CommunicationSubscriptionCommandDispatcher.swift Tests/Communication/CommunicationSubscriptionCoordinatorTests.swift
git commit -m "feat(communication): isolate subscription command delivery"
```

### Task 2: Make the coordinator the manager’s subscription owner

**Files:**
- Modify: `Source/Communication/Manager/CommunicationManager.swift`
- Modify: `Tests/Communication/EventHubTransportTests.swift`

**Interfaces:**
- Consumes: dispatcher delivery; coordinator `acquire(topic:)`, `release(topic:)`, `setOnline(_:)`, and `reset()`.
- Produces: manager helpers with no `subscriptions` or `deferredSubscriptions` storage.

- [ ] **Step 1: Write failing manager integration tests**

Extend `FakeCommunicationClient` with `[SubscriptionCommand]` recording. Cover offline acquisition then online replay, duplicate acquisition, final release, and reset:

```swift
@Test func managerReplaysDesiredTopicsOnceAfterOnline() async throws {
    let manager = makeManager(); let client = FakeCommunicationClient(delegate: manager)
    manager.client = client
    manager.subscribe(topic: "coaty/test/#")
    #expect(client.commands == [])
    await client.simulateState(.online)
    try await eventually { client.commands == [.subscribe("coaty/test/#")] }
}
```

- [ ] **Step 2: Run it and verify red**

Run: `make test-communication`

Expected: FAIL because the manager still owns its subscription maps.

- [ ] **Step 3: Integrate the coordinator**

Construct the MQTT client, dispatcher, and coordinator together in `CommunicationManager.init`. The sink must capture only the dispatcher actor:

```swift
let dispatcher = CommunicationSubscriptionCommandDispatcher(client: client)
subscriptionCoordinator = CommunicationSubscriptionCoordinator { command in
    await dispatcher.deliver(command)
}
```

Replace map mutation in `subscribe(topic:)`/`unsubscribe(topic:)` with tasks that capture only `subscriptionCoordinator`. Add a dedicated state observer capturing a local coordinator and calling `setOnline(state == .online)`. Remove deferred-subscription replay from `setupOnConnectHandler`, retain publication replay, and reset coordinator state in `endClient`.

- [ ] **Step 4: Verify green**

Run: `make test-communication`

Expected: PASS, including state replay and new command assertions.

- [ ] **Step 5: Commit**

```bash
git add Source/Communication/Manager/CommunicationManager.swift Tests/Communication/EventHubTransportTests.swift
git commit -m "refactor(communication): centralize subscription ownership"
```

### Task 3: Expose lifecycle-safe async Advertise streams

**Files:**
- Create: `Source/Communication/Manager/CM+AdvertiseStream.swift`
- Modify: `Tests/Communication/EventHubTransportTests.swift`

**Interfaces:**
- Produces: `observeAdvertiseStream(withCoreType:) async -> EventStream<AdvertiseEventSnapshot>`.
- Produces: `observeAdvertiseStream(withObjectType:) async throws -> EventStream<AdvertiseEventSnapshot>`.

- [ ] **Step 1: Write failing stream tests**

Verify core-type first iterator subscription, snapshot delivery, last-iterator cancellation release, and no duplicate subscription. Add object-type cases for known core type (object key), valid unknown type (base key), and invalid type (`AxolotyError.InvalidArgument`):

```swift
let stream = await manager.observeAdvertiseStream(withCoreType: .Log)
let task = Task { var iterator = stream.makeAsyncIterator(); return await iterator.next() }
try await eventually { client.commands == [.subscribe(expectedTopic)] }
await client.emit(snapshot, to: CommunicationEventHubKeys.advertise(eventTypeFilter: CoreType.Log.rawValue))
#expect(await task.value == snapshot)
```

- [ ] **Step 2: Run it and verify red**

Run: `make test-communication`

Expected: compile failure because the public async Advertise methods do not exist.

- [ ] **Step 3: Implement stream registration**

Derive topics exactly as `CM+Observe.swift`: use the core topic/object key when `CoreType.getCoreType(forObjectType:)` succeeds; otherwise use the object topic/base key. Register `.event` and capture only Sendable values:

```swift
let coordinator = subscriptionCoordinator
return await eventHub.registerStream(
    key: key, buffering: .event,
    onFirst: { Task { await coordinator.acquire(topic: topic) } },
    onLast: { Task { await coordinator.release(topic: topic) } }
)
```

Do not convert `AdvertiseEventSnapshot` into mutable `AdvertiseEvent`.

- [ ] **Step 4: Verify green**

Run: `make test-communication`

Expected: PASS with cancellation, ref-count, filter, metadata, and invalid-input assertions.

- [ ] **Step 5: Commit**

```bash
git add Source/Communication/Manager/CM+AdvertiseStream.swift Tests/Communication/EventHubTransportTests.swift
git commit -m "feat(communication): add async advertise streams"
```

### Task 4: Verify T-039 and record the migration boundary

**Files:**
- Modify: `docs/ROADMAP.md`
- Modify: `docs/superpowers/specs/2026-07-15-t039-subscription-coordinator-design.md`

**Interfaces:**
- Consumes: all preceding tests.
- Produces: documented T-039 status and next step to migrate Advertise consumers before deleting temporary Rx APIs.

- [ ] **Step 1: Update documentation after behavior is green**

Mark T-039 complete and state that controller, IO routing, SensorThings, and test Advertise consumers must move to snapshots before Rx Advertise methods are removed.

- [ ] **Step 2: Run canonical verification**

Run: `make build && make test`

Expected: both commands exit 0. Do not claim completion if a container, broker, or test failure prevents this result.

- [ ] **Step 3: Inspect static constraints**

Run: `rg -n '@unchecked Sendable' Source/Communication/Manager && rg -n 'subscriptions|deferredSubscriptions' Source/Communication/Manager/CommunicationManager.swift`

Expected: no new production `@unchecked Sendable`; neither legacy subscription-state property remains in the manager.

- [ ] **Step 4: Commit**

```bash
git add docs/ROADMAP.md docs/superpowers/specs/2026-07-15-t039-subscription-coordinator-design.md
git commit -m "docs: record subscription coordinator migration"
```
