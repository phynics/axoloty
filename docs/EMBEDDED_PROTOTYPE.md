# Embedded Swift prototype

The first #111 gate is a Linux x86 host prototype. It is intentionally
separate from the Foundation/NIO-backed `Axoloty` target.

## Current proof

The development container's Swift 6.3 toolchain compiles and runs
`Embedded/Probe/main.swift` with:

```sh
swiftc -enable-experimental-feature Embedded \
  -wmo -parse-as-library Embedded/Probe/main.swift \
  -o .build/embedded-probe
```

The probe emits the statically typed JSON payload:

```json
{"message":"embedded"}
```

Use the repository targets so the container remains canonical:

```sh
make embedded-build
make embedded-test
```

## Explicit limits

- This proves only the host Embedded Swift compiler/runtime seam.
- It does not claim ESP32-C6 support or provide an ESP32-C6 cross-toolchain.
- `WireDecodable`, IkigaJSONCore parsing, and the full embedded object model
  remain subsequent #111 work.
- Foundation, `Codable`, `Any`, reflection, and dynamic protocol casts are not
  used by the probe.

The ESP32-C6 toolchain and on-device concurrency proof remain a #96 gate.
