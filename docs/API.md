# Axoloty 0.5.1 API documentation

> Axoloty 0.5.1 is a development checkpoint. Public APIs may continue to
> change before 1.0.

## Borrowed-value lifetime rules

Wire-codec views such as `BorrowedMessage`, `ByteSlice`, and `TopicView`
borrow externally owned bytes for synchronous, zero-copy work. The
following rules are mandatory:

1. **Never retain borrowed views.** Borrowed bytes are valid only for the
   duration of the callback or buffer that owns them. Do not store a
   `BorrowedMessage`, `ByteSlice`, or `TopicView` in a property, array, or
   capture.

2. **Never cross async seams.** Borrowed views are not `Sendable`. Do not
   pass them across actor boundaries, into `Task` bodies, or through
   `AsyncStream` continuations. Copy the data into an owned `String` or
   `[UInt8]` before any suspension point.

3. **Validate before use.** Always call the validation method (e.g.
   `BorrowedMessage.validated(topicBytes:topicLength:payloadBytes:payloadLength:)`)
   before accessing borrowed fields from untrusted input.

4. **Copy before returning.** If a borrowed value must outlive its
   callback, copy the relevant bytes into an owned allocation first.

## Owned raw JSON construction

Owned wire payload types store independent `[UInt8]` copies. Every public raw-
byte initializer validates complete JSON syntax and the semantic shape required
by each event field before publishing the owned value, and throws
`WireDecodeError` on failure.

`BorrowedWireEvent.owned()` copies fields and performs the same validation
before returning. Malformed borrowed data therefore cannot cross the ownership
boundary. The package remains Foundation-free; callers receive the structured
wire error and Axoloty API boundaries wrap it as `AxolotyError`.

The host adapter validates Codable-produced raw fields with Foundation's JSON
parser, then calls the same public validating constructors. Host-sized values
are revalidated by the Foundation-free wire layer within the bounded host
payload limit. There is no cross-module unchecked construction route. Internal
unchecked initializers are used only by those validating constructors.
Validation failures are wrapped as `AxolotyError.caught`, preserving the
underlying `WireDecodeError` for cause-chain diagnostics.

## Suspension points

The following public API operations may suspend (`async` or `async throws`):

### Container and communication-manager lifecycle
Synchronous start and asynchronous readiness waiting are separate APIs:

- `Container.resolve(components:configuration:)` — `throws` (synchronous);
  bootstraps the container and its communication manager without connecting
  to the broker.
- `CommunicationManager.start()` — `throws` but **synchronous**; connects
  the MQTT client and transitions the operating state to `.started` without
  suspending. Throws `AxolotyError.invalidConfiguration(option:reason:)` if
  the MQTT client options are missing on the restart path.
- `Container.startAndWaitUntilReady()` — `async throws`; prepares registered
  controllers, starts communication, and waits until their desired
  subscriptions are acknowledged by the broker. Use this to await readiness.
- `CommunicationManager.startAndWaitUntilReady()` — internal; awaits
  broker connection and subscription completion.

### Observation streams
All `observe*Stream()` methods return `AsyncStream<T>` which suspends while
waiting for the next event:
- `observeAdvertiseStream(withCoreType:)` — `async`
- `observeAdvertiseStream(withObjectType:)` — `async throws`
- `observeAdvertiseStream()` — `async` (namespace-wide, no type filter)
- `observeDeadvertiseStream()` — `async`
- `observeDiscoverStream()` — `async`
- `observeQueryStream()` — `async`
- `observeCallStream(operation:)` — `async throws`
- `observeUpdateStream(withCoreType:)` — `async`
- `observeChannelStream(channelId:)` — `async throws`
- `observeIoValueStream()` — `async`
- `observeIoStateStream(ioPoint:)` — `async`
- `observeOperatingStateStream()` — `async`
- `observeCommunicationStateStream()` — `async`
- `observeRawMQTTMessageStream()` — `async`

For provider-side unary handling, use
`registerCallHandler(operation:context:handler:)` — `async throws`. It returns a
`CallHandlerRegistration` that explicitly owns observation and in-flight task
lifetime. Retain it while active and call `cancel()` to unregister. Incoming
context filters are matched before provider code runs, correlation identifiers
are handled at most once, and the registration publishes the correlated
`ReturnEvent` internally from a `CallHandlerResult`. The raw
`observeCallStream(operation:)` API remains available for lower-level consumers.

### Request/response publishing
These publish an event and return an `AsyncStream` of responses, which
suspends while waiting for peer replies:
- `publishDiscover(_:)` — `async`
- `publishQuery(_:)` — `async`
- `publishUpdate(_:)` — `async`
- `publishCall(_:)` — `async`

For a single generic Call/Return exchange, use
`call(operation:parameters:context:timeout:)` — `async throws`. It installs
the correlated Return observation before publishing the Call and returns a
`UnaryCallResult` for the first Return. Observation ownership is released on
success, remote error, malformed response, timeout, or caller cancellation, so
duplicate and late Returns are ignored. `publishCall(_:)` remains the API for
multi-response behavior.

The unary API accepts parameters as optional raw JSON object or array text and
an optional domain-neutral `ContextFilter` used by providers for selection.
Its successful `result` and `executionInfo` remain raw JSON text and its
`sourceId` identifies the responding provider when the wire topic supplies it.
Remote Return errors throw `RemoteCallFailure`, preserving the remote numeric
`code` and `message`. A malformed Return throws `AxolotyError.decodingFailure`;
timeout and caller cancellation throw `AxolotyError.runtime` with `.timedOut`
and `.cancelled`, respectively. The timeout must be greater than zero.

### Raw publish
- `publishRaw(topic:withString:)` — synchronous (no suspension)
- `publishRaw(topic:withBinary:)` — synchronous (no suspension)

## AxolotyError categories

`AxolotyError` is the package's `Throwable` base error type. It has six
stable cases:

| Case | Associated values | When to throw |
|---|---|---|
| `.invalidArgument` | `argument: String`, `reason: String` | A caller passed an invalid argument value (e.g. invalid topic name). |
| `.decodingFailure` | `type: String`, `reason: String`, `payload: String?` | A Coaty object or event could not be decoded. The optional payload aids debugging. |
| `.invalidConfiguration` | `option: String`, `reason: String` | A configuration option is missing or has an invalid value. |
| `.runtime` | `code: RuntimeErrorCode`, `reason: String` | A runtime condition failed. The code is a stable, machine-readable enum that downstream code may switch on. |
| `.network` | `error: Error`, `reason: String` | A transport-level network error caught at an API boundary. The original foreign error is preserved for chain diagnostics. |
| `.caught` | `Error` | A foreign error wrapped at an Axoloty API boundary via `AxolotyError.caught(_:)`. Never let a bare `Error` escape an Axoloty API. |

### RuntimeErrorCode

`RuntimeErrorCode` is a semver-relevant public surface. Downstream code
switches on it, so additions are additive-only:

| Code | When |
|---|---|
| `.notStarted` | A component was used before being started. |
| `.timedOut` | A wait for a runtime condition exceeded its deadline. |
| `.cancelled` | An asynchronous operation was cancelled by its caller. |
| `.streamEnded` | An event or state stream ended before delivering an expected value. |
| `.brokerUnavailable` | No broker could be reached or discovered. |
| `.subscriptionFailed` | A topic subscription was rejected by the transport. |
| `.notRegistered` | A referenced entity (e.g. a sensor) was not registered. |

## Initialization and lifecycle invariants

1. **Container before manager.** A `Container` must be bootstrapped from
   `Configuration` before a `CommunicationManager` is created. The
   container resolves controllers and communication components.

2. **Start before use.** `Container.startAndWaitUntilReady()` must complete
   before any observe or publish API is called. Calling these before
   start throws `AxolotyError.runtime(code: .notStarted)`.

3. **Main-actor isolation.** `CommunicationManager` is `@MainActor`.
   All public observe/publish methods execute on the main actor. The
   underlying MQTT client delivers messages from a non-main context;
   the manager bridges via `onMain(_:)`.

4. **Shutdown is final.** After `Container.shutdown()` (which disposes the
   communication manager via `CommunicationManager.onDispose()`), the
   container and its manager cannot be restarted. Create a new `Container`
   and `CommunicationManager` for a fresh lifecycle. By contrast,
   `CommunicationManager.stop()` is reversible: invoke `start()` to
   reconnect and continue processing.

5. **Dynamic controller registration.**
   `Container.registerController(name:controllerType:controllerOptions:)`
   can register a controller after bootstrap. If the manager is already
   started, the controller's `onCommunicationManagerStarting()` is called
   immediately.

## `@unchecked Sendable` audit

All five production `@unchecked Sendable` declarations are internal or
private, with documented synchronization rationale:

| Type | File | Visibility | Justification |
|---|---|---|---|
| `CoreTypeKeysContext` | `AnyCoatyObjectDecodable.swift` | internal | Mutable state accessed only synchronously during one decode; stack's single-decode ownership prevents concurrent mutation. |
| `DecodingContextStack` | `Decoder+Context.swift` | internal | Stored in `JSONDecoder.userInfo`; mutable state accessed only synchronously during one decode. `JSONDecoder` does not invoke decoders concurrently. |
| `RawJSONObjectContext` | `RawJSONObjectContext.swift` | internal | Created for one decode operation; `currentObject` accessed only synchronously by that operation; never shared by concurrent decodes. |
| `MQTTNIOCallbackAdapter` | `MQTTNIOClient.swift` | private | mqtt-nio invokes callbacks from independent contexts; `NIOLock` guards delegate, stream, and client access. |
| `LevelStore` | `LogManager.swift` | private | `NSLock` guards every read and write of subsystem levels and default level. |

No public types use `@unchecked Sendable`. No unjustified uses were found.
