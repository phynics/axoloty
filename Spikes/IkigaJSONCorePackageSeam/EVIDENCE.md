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

The preferred durable seam is an upstream manifest fix followed by an upstream
standalone or conditionally declared core package that does not resolve NIO.
Upstream issue
[`orlandos-nl/swift-json#63`](https://github.com/orlandos-nl/swift-json/issues/63)
already tracks the missing Swift 6.2+ product. The minimal manifest correction
has been submitted upstream as
[`orlandos-nl/swift-json#68`](https://github.com/orlandos-nl/swift-json/pull/68).

Until upstream provides a no-NIO resolution seam, production AxolotyWire should
not silently add swift-json to its standalone package. Root-only adapter work
can proceed, and a temporary pinned fork is acceptable for integration testing,
but vendoring parser sources is not selected by this issue.
