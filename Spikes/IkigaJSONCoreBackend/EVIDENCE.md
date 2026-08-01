# Issue #392 spike: IkigaJSONCore backend

## Reproduction

From the repository root, run through the pinned Swift 6.3 container:

```sh
CONTAINER_RUNTIME=podman IMAGE=axoloty-dev \
BUILD_DIR=/tmp/coaty-swift-build/axoloty/swift-6.3-linux/worktrees/392-ikigajsoncore-backend/debug \
SPM_CACHE_DIR="$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux" \
.devcontainer/run.sh sh Spikes/IkigaJSONCoreBackend/check.sh
```

The isolated package pins `swift-json` 2.5.3 at revision
`216e30b22ef3c4180e126f284a4c62d51a1c1049`, matching the root
`Package.resolved`. Its only probe imports `IkigaJSONCore`; it intentionally
does not substitute `IkigaJSON`/`JSONObject`/`Codable`.

## Observed package surface

`swift package dump-package` at the pinned checkout reports one public product:
`IkigaJSON`, backed by target `IkigaJSON`. It also reports package-access-only
targets `_JSONCore` and `_NIOJSON`; neither is a product or importable module
for a dependent package. The checkout has no `IkigaJSONCore` target.

## Results

- Host Linux: the isolated SwiftPM build rejects `import IkigaJSONCore` with
  `no such module 'IkigaJSONCore'`.
- Embedded Swift probe: the RISC-V compile rejects the same import with
  `no such module 'IkigaJSONCore'`.
- Dependency surface: the isolated package resolves `swift-json` plus its
  `swift-nio`/`swift-system`/`swift-atomics`/`swift-collections` closure;
  there is no `IkigaJSONCore` dependency or product to link.
- Binary observation: both probes fail before object/executable emission, so
  there is no candidate backend binary or size contribution to measure.
- No typed ASC/IOV adapter was added because the proposed module is absent.
- No AxolotyWire manifest or production codec path was changed.

## Verdict

Pinned `swift-json` 2.5.3 cannot be the shared `IkigaJSONCore` backend as
published. A future spike would require an upstream public product/module (or
an explicitly approved upstream/API change); this bounded spike does not
reach into the package's package-private `_JSONCore` implementation.
