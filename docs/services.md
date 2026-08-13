# Local services

Axoloty provides one foreground command surface for the local Mosquitto broker
and the Axoloty MCP server:

```sh
ax serve mqtt
ax serve mcp --transport stdio
ax serve mcp --transport http       # http://127.0.0.1:8765/mcp
ax serve dev                        # MQTT 127.0.0.1:1883 + MCP HTTP 127.0.0.1:8765/mcp
```

Every service remains in the foreground. Press Ctrl-C to stop it. The commands
return 64 for invalid arguments, 69 when an executable is missing or a port is
occupied, 70 for setup, start, or readiness failures, and 130 when
interrupted. Standalone MQTT and MCP commands return 1 when their child exits
nonzero; the development stack returns the exiting child's status. A normally
exiting child returns 0.

## Installation and wrappers

On Linux, `make image` installs non-interactive mounted-worktree launchers at
`/opt/axoloty/bin/ax` and `/opt/axoloty/bin/axoloty-mcp`.
`/opt/axoloty/bin/axoloty-tool` is the matching typed-control-plane launcher.
All three run their product with `swift run` against the mounted worktree and
cache. Use the thin in-container wrappers:

```sh
make serve-mqtt
make serve-mcp                              # stdio transport
make serve-mcp SERVE_MCP_ARGS='--transport http'
make serve-dev
```

The wrappers use host networking because services bind only to loopback; no
service policy is implemented in Make or shell. On macOS, run the root package
natively:

```sh
swift run --package-path . ax serve mqtt
swift run --package-path . ax serve mcp --transport http
swift run --package-path . ax serve dev
```

`make broker` and `make broker-stop` remain for compatibility and print a
deprecation warning. Prefer `make serve-mqtt`.

## MQTT service

`ax serve mqtt` starts Mosquitto with an ephemeral generated configuration.
It defaults to `127.0.0.1:1883`; use `--listen-host`, `--port`, `--output`,
and `--log-level` to configure its address, port, readiness format, and
diagnostic level. It reports readiness after accepting TCP connections, with a
five-second deadline.

## MCP service

`ax serve mcp` requires one of these explicit transports:

- `--transport stdio` runs JSON-RPC over standard input and output and opens no
  listener. Do not write diagnostics to standard output.
- `--transport http` serves Streamable HTTP at
  `--listen-host`/`--listen-port`/`--path`, defaulting to
  `127.0.0.1:8765/mcp`. HTTP binds only to loopback and has a ten-second
  readiness deadline.

Both transports accept `--broker-host`, `--broker-port`, and `--namespace` to
connect to MQTT, plus `--connect-timeout`. HTTP also accepts `--listen-host`,
`--listen-port`, `--path`, and `--output`.

The server exposes the read-only resources `axoloty://status` and
`axoloty://catalogue`, plus these tools:

- `axoloty_list_objects` lists objects in the passive catalogue.
- `axoloty_get_object` retrieves a catalogue object by ID.
- `axoloty_discover_objects` sends one bounded Discover request and collects
  Resolve responses.
- `axoloty_server_status` reports MQTT connection state and catalogue metrics.

The catalogue is deliberately incomplete: it contains only objects advertised
after the observer connected. The server offers no arbitrary MQTT publish or
subscribe operation. Keep HTTP loopback-only; expose it remotely only through
an authenticated, deliberately configured proxy.

## Development stack

`ax serve dev` starts MQTT first, waits for it, starts MCP HTTP, then reports
both endpoints. It defaults to MQTT port 1883 and MCP port 8765. Use
`--mqtt-port`, `--mcp-port`, `--namespace`, and `--output human|json` to change
the ports, namespace, and readiness format. If either child exits, the runner
terminates its sibling and returns the exiting child's status.
