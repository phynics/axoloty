# Changelog

All notable changes to Axoloty are documented in this file.

Axoloty is a modernized fork of
[CoatySwift](https://github.com/coatyio/coaty-swift). Releases made before the
fork, through CoatySwift 2.4.0, remain documented in the
[upstream changelog](https://github.com/coatyio/coaty-swift/blob/master/CHANGELOG.md).

## [Unreleased]

Development toward Axoloty 1.0 is in progress and tracked by the
[v1 release epic](https://github.com/phynics/axoloty/issues/272).

### Changed

- **Breaking:** Renamed the public Coaty task model from `Task` to
  `CoatyTask` so it no longer conflicts with Swift Concurrency's `Task`.
  Replace model references to `Task` with `CoatyTask`; unqualified `Task` now
  denotes Swift Concurrency's type. No deprecated compatibility alias is
  provided. The wire-level `Task` core type and `coaty.Task` object type are
  unchanged.

## [0.1.0] - 2026-07-13

Initial Axoloty prerelease as an independently maintained, modernized fork of
CoatySwift.

[Unreleased]: https://github.com/phynics/axoloty/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/phynics/axoloty/releases/tag/v0.1.0
