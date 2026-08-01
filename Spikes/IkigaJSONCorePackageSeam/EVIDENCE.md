<!-- Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License. -->

# Issue #394: IkigaJSONCore package seam

## Reproduction

Run `sh Spikes/IkigaJSONCorePackageSeam/check.sh` through the repository's
pinned Swift 6.3 container.

The check resolves pinned swift-json 2.5.3, applies the minimal product patch to
its Swift 6.3 version-specific manifest, and builds a real SwiftPM consumer that
selects product `IkigaJSONCore` and imports module `_JSONCore`. It separately
cross-compiles the same target and consumer for Embedded RISC-V.

## Expected architectural result

The product patch should require no parser source changes. `_JSONCore` should
compile without Foundation or NIO, while SwiftPM's package graph should still
resolve swift-nio because the enclosing swift-json manifest declares it
unconditionally. Resolution and runtime linkage are reported separately.

## Results

The patched product is consumable through SwiftPM on Swift 6.3. The release
build compiled only `_JSONCore` and the consumer target and ran successfully;
NIO was not linked into the executable.

The same core and consumer compiled for `riscv32-none-none-eabi`. The check
also performs a partial relocatable link so a compile-only result cannot hide
cross-module ABI or symbol failures. The verified sizes were: `_JSONCore`
32,412 bytes, Embedded consumer 14,660 bytes, partial linked object 45,264
bytes, and host release consumer executable 225,240 bytes.

SwiftPM still resolves swift-nio and its transitive packages because
swift-json declares NIO as an unconditional package dependency. Disabling
Foundation/NIO traits prevents those targets from building but cannot remove
them from package resolution. In an isolated consumer the broad `from: 2.0.0`
constraint may also resolve newer NIO/System patch releases than Axoloty's
current graph unless the consumer pins them.

## Package-seam decision

Axoloty accepts swift-nio and its transitives in package resolution as long as
they do not prevent Linux or Embedded compilation and no NIO target is built or
linked into AxolotyWire. This distinguishes dependency resolution cost from the
runtime and firmware dependency closure; a standalone or conditionally declared
core package would be an optimization, not a production prerequisite.

The selected distribution is the pinned upstream swift-json package with the
minimal product exposure fix. Upstream issue
[`orlandos-nl/swift-json#63`](https://github.com/orlandos-nl/swift-json/issues/63)
already tracks the missing Swift 6.2+ product. The minimal manifest correction
has been submitted upstream as
[`orlandos-nl/swift-json#68`](https://github.com/orlandos-nl/swift-json/pull/68).

Axoloty will keep the swift-json revision locked in `Package.resolved`, review
upstream source and license changes before updating it, and rerun this host and
Embedded compile/link check for each update. An update is rejected if NIO begins
building or linking, or if swift-json no longer compiles on either platform.
Until pull request #68 is available in an upstream release, integration may use
a minimal pinned fork containing only that manifest correction. Vendoring parser
sources is not selected by this issue.
