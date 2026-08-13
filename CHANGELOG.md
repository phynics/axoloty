# Changelog

All notable changes to Axoloty are documented in this file.

Axoloty is a modernized fork of
[CoatySwift](https://github.com/coatyio/coaty-swift). Releases made before the
fork, through CoatySwift 2.4.0, remain documented in the
[upstream changelog](https://github.com/coatyio/coaty-swift/blob/master/CHANGELOG.md).

## [Unreleased]

Development toward Axoloty 1.0 is in progress and tracked by the
[v1 release epic](https://github.com/phynics/axoloty/issues/272).

## [0.4.0] - 2026-08-14

Axoloty 0.4.0 is a development checkpoint and is not API-stable.

### Added

- Public Discover responder registration, decoded Coaty object access, join
  condition state, and configurable association update rates.
- A canonical typed test driver with bounded process ownership and shared,
  process-aware device leases.
- Stable embedded runtime identities and stage-rich evidence schema v2.

### Changed

- **Breaking:** Owned `AxolotyWire` raw-JSON initializers and
  `BorrowedWireEvent.owned()` now throw `WireDecodeError` after validating JSON
  syntax and the required wire shape. Add `try` and handle malformed input.
- Inspector `json` output now emits one complete JSON array; `ndjson` remains
  the streaming one-record-per-line format. Resolve discovery now preserves
  related objects, and private payloads require both `--full` and
  `--include-private-data`.
- Build and test compilation now treats Swift warnings as errors.

### Fixed

- Hardened malformed wire, model-filter, IoState, SensorThings, and
  distribution-boundary handling.
- Corrected MQTT QoS, subscription reset, Bonjour retry, Call correlation,
  runtime state-stream, and publication-completion behavior.
- Stabilized embedded linking, callback synchronization, test process
  isolation, development-image reuse, and warning-free firmware/test builds.
- Distinguished MCP stream exhaustion from deadline timeout and bounded MCP
  HTTP request bodies.

## [0.3.0] - 2026-08-04

### Added

- Generic unary Call/Return client APIs and generic Call handler registration.
- Static bounded embedded IoSource and IoActor endpoint support.

### Changed

- Host communication traffic uses `AxolotyWire`.
- **Breaking:** Renamed the public Coaty task model from `Task` to `CoatyTask`
  to avoid conflict with Swift Concurrency's `Task`. The wire-level core and
  object type names remain unchanged.

### Fixed

- MCP HTTP shutdown lifecycle cleanup.

## [0.2.0] - 2026-07-31

Development checkpoint establishing the Swift 6 host safety boundary, the
Foundation-free `AxolotyWire` package boundary, ESP32-C6 Embedded Swift
Advertise/Deadvertise and Discover/Resolve support, typed repository tooling,
and reproducible compatibility and resource evidence.

## [0.1.0] - 2026-07-13

Initial Axoloty prerelease as an independently maintained, modernized fork of
CoatySwift.

[Unreleased]: https://github.com/phynics/axoloty/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/phynics/axoloty/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/phynics/axoloty/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/phynics/axoloty/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/phynics/axoloty/releases/tag/v0.1.0
