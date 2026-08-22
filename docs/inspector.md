# Axoloty MQTT Object Inspector

The `axoloty-inspect` CLI connects to an MQTT broker through Axoloty and
inspects live Coaty objects without writing a custom agent.

## Commands

### `catalog` — passive observation

Observe Advertise and Deadvertise events and maintain an in-memory object
catalogue. Publishes no Coaty events.

```sh
axoloty-inspect catalog --duration 10s
axoloty-inspect catalog --core-type Identity --namespace test-ns
axoloty-inspect catalog --output ndjson | jq -c .
axoloty-inspect catalog --output json --duration 10s | jq .
```

Valid core types: `CoatyObject`, `User`, `Annotation`, `Task`, `IoSource`,
`IoActor`, `IoNode`, `IoContext`, `Identity`, `Log`, `Location`, `Snapshot`.
For SensorThings types (e.g. `Sensor`, `Thing`, `Observation`) use
`--object-type` instead.

### `discover` — active discovery

Send one Discover request, collect Resolve responses, and print a finite
result. Requires at least one selector.

```sh
axoloty-inspect discover --core-type Identity
axoloty-inspect discover --object-type com.example.Sensor --timeout 5s
axoloty-inspect discover --object-id abc-123-def-456
```

A zero-result discovery is successful (`timedOut: true, objects: []`).
A broker failure is distinguishable from no responses (nonzero exit code).

## Connection options

| Option | Default | Environment | Description |
|---|---|---|---|
| `--host HOST` | `localhost` | `AXOLOTY_MQTT_HOST` | Broker host |
| `--port PORT` | `1883` | `AXOLOTY_MQTT_PORT` | Broker port |
| `--namespace NS` | `-` | `AXOLOTY_NAMESPACE` | Coaty namespace |
| `--tls` | off | — | Enable TLS |
| `--username USER` | none | `AXOLOTY_MQTT_USERNAME` | Broker username |
| `--password-stdin` | off | — | Read password from stdin |
| `--connect-timeout D` | `10s` | — | Connection readiness timeout |
| `--log-level LEVEL` | `info` | — | Diagnostic log level |

Precedence: CLI option > environment variable > built-in default.

## Catalogue filters

Filters are ANDed: an object must match all specified fields.

| Option | Description |
|---|---|
| `--core-type TYPE` | Filter by core type (e.g. `Identity`, `Task`, `Log`) |
| `--object-type TYPE` | Filter by full object type |
| `--object-id UUID` | Filter by object UUID |
| `--source-id UUID` | Filter by source (advertiser) UUID |
| `--full` | Include complete raw JSON payload |
| `--include-private-data` | Include private data (requires `--full`) |

Deadvertise removal is not affected by filters: objects that entered the
catalogue are removed by later Deadvertise events regardless of filter
fields.

## Output modes

| Mode | Description |
|---|---|
| `auto` | Human format for TTY, NDJSON for pipes (default) |
| `human` | One-line-per-event terminal output |
| `ndjson` | Newline-delimited JSON, one self-contained object per line |
| `json` | One sorted-key JSON array emitted when the finite command completes |

**stdout** carries data records only. **stderr** carries diagnostics,
progress, and errors. Connection messages are never written to stdout.

NDJSON streams records as they occur. JSON buffers records until completion and
emits exactly one array, so `catalog --output json` requires a finite
`--duration`; unlimited catalogue JSON is rejected during argument validation.
Discovery may use JSON without a timeout when its response stream naturally
ends.

### Record schema

Every NDJSON line, and every element of a JSON array, is a complete JSON object
with schema `axoloty.inspect/v1`:

```json
{
  "schema": "axoloty.inspect/v1",
  "kind": "advertise",
  "timestamp": "2026-07-31T17:30:00Z",
  "namespace": "example",
  "sourceId": "source-uuid",
  "objectId": "object-uuid",
  "coreType": "Identity",
  "objectType": "coaty.object.Identity",
  "name": "Agent"
}
```

Record kinds: `session-started`, `advertise`, `object-updated`,
`deadvertise`, `session-ended`, `error`, `discovery-result`.

Payload and private data are omitted by default. Use `--full` to include
the raw JSON payload. Private data is included only when both `--full` and
`--include-private-data` are supplied; `--full` does not imply
`--include-private-data`.

### Human format

```
CONNECTED  namespace=example
ADD        Identity     Agent A          abcd…7890
UPDATE     Sensor       Temperature      e8b1…70ac
REMOVE     Identity                      abcd…7890
DISCONNECTED
```

Object IDs are truncated to `XXXX…XXXX` for display.

## Credentials and redaction

- No `--password VALUE` flag exists. Passwords are never accepted as a
  CLI argument (process table exposure).
- Use `--password-stdin` to read the password from one line of stdin.
- The `AXOLOTY_MQTT_PASSWORD` environment variable is also supported.
- Passwords are never printed in output, logs, or error messages.
- `InspectorConnectionConfiguration` overrides `CustomStringConvertible`
  to redact credentials in all descriptions.

```sh
printf '%s\n' 'secret' | axoloty-inspect catalog --username operator --password-stdin --duration 1s
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Completed successfully |
| 1 | Operation or protocol failure |
| 64 | Invalid arguments or configuration |
| 69 | Broker or required service unavailable |
| 70 | Unexpected internal failure |
| 130 | Interrupted by SIGINT |

## Passive vs active behavior

- **Passive catalogue** (`catalog`): observes Advertise and Deadvertise
  events. Publishes no Coaty events. The catalogue is observed, not
  authoritative or complete — it reflects only what was advertised during
  the observation window.
- **Active discovery** (`discover`): publishes exactly one Discover
  event. Collects Resolve responses. Does not mutate any objects.

## Architecture

```
axoloty-inspect (executable)
    ├── Axoloty (AxolotyRuntime + MQTTBinding)
    └── AxolotyInspectorCore (pure: catalogue, filter, reducer, records)
```

`AxolotyInspectorCore` has no product-runtime dependencies. The CLI
target depends on `Axoloty` for broker connectivity through
`AxolotyRuntime` and `MQTTBinding`. `AxolotyTooling` is unaffected — its
dependency closure does not change.

The inspector does not instantiate MQTTNIO directly. It builds an immutable
runtime definition and uses the runtime-owned event streams for observation.

## Testing

- **Pure core tests** (`AxolotyInspectorCoreTests`): catalogue reducer,
  filter, records, duration parsing, argument parsing — no broker needed.
- **Application tests** (`AxolotyInspectorCLITests`): fake session tests
  for application orchestration, output formatting, cancellation — no
  broker needed.
- **Broker integration tests** (`InspectorBrokerIntegrationTests`):
  env-gated tests against a real Mosquitto broker. Enable with
  `AXOLOTY_INSPECTOR_LIVE=1`.

All tests use Swift Testing (`import Testing`, `@Test`, `#expect`).

## Build

On macOS:

```sh
swift build --product axoloty-inspect
swift test --filter AxolotyInspector
```

On Linux, use the pinned container via the Makefile env or `.devcontainer/run.sh`:

```sh
CONTAINER_RUNTIME=podman IMAGE=axoloty-dev \
BUILD_DIR=.build BUILD_LOCK=0 \
SPM_CACHE_DIR="$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux" \
.devcontainer/run.sh swift build \
  --cache-path /workspace/.swiftpm-cache \
  --disable-automatic-resolution \
  --product axoloty-inspect

CONTAINER_RUNTIME=podman IMAGE=axoloty-dev \
BUILD_DIR=.build BUILD_LOCK=0 \
SPM_CACHE_DIR="$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux" \
.devcontainer/run.sh swift test \
  --cache-path /workspace/.swiftpm-cache \
  --disable-automatic-resolution \
  --filter AxolotyInspector
```

The `--disable-automatic-resolution` flag is mandatory because
`Package.resolved` is checked in. See
[AGENTS.md](../AGENTS.md) for the full container build/test reference.
