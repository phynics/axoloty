# Optional root Zenoh packaging experiment

This experiment answers whether a root `AxolotyZenoh` product can coexist with
Core-only root builds when Linux has no native `zenoh-c` installation. Its
root-product candidate fails the required default-build condition, so the
production manifest remains unchanged.

## Recreate the candidate

Run from the checkout root:

```sh
Spikes/OptionalZenohPackaging/prepare-candidate.sh
```

The script extracts base commit `0c74f3ae2328a8dc1528088f7b7d3be24f7cf241`
into ignored `.testing/runs/optional-zenoh-1001/rerun-candidate` and applies
[`root-product.patch`](root-product.patch). The resulting exact candidate
`Package.swift` SHA-256 is
`9b94759cfb5e7cb5dc6fe3abc6602e7dba3057767efde7f6c08532d0433dcaf4`.

The patch adds a root `AxolotyZenoh` product, a `CZenohC` system library with
`pkgConfig: "zenohc"`, and the existing C façade, Zenoh core, and host adapter
targets. It adds no new SwiftPM package dependency. The patch is the complete
candidate-manifest delta; apply it to the pinned base to recover that manifest.

## Reproduce on Linux

Use the repository's pinned image and private build/cache directories. The
following checks the candidate default build and then the selected Core product
with the same empty native environment:

```sh
flock /tmp/axoloty-batch2-382c4846/verification.lock \
  env CONTAINER_RUNTIME="$(command -v podman)" IMAGE=axoloty-dev \
  BUILD_DIR=/tmp/axoloty-1001-build SPM_CACHE_DIR=/tmp/axoloty-1001-spm \
  .devcontainer/run.sh sh -c '
    if pkg-config --exists zenohc; then
      echo "Zenoh unexpectedly installed" >&2; exit 1
    fi
    cd /workspace/.testing/runs/optional-zenoh-1001/rerun-candidate
    env -u PKG_CONFIG_PATH swift build \
      --scratch-path /workspace/.build/optional-zenoh-1001/replay-default \
      --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution
  '
```

The default build is expected to fail in `CAxolotyZenoh` with `zenoh.h` not
found. Replace the `swift build` command with
`swift build --product Axoloty` and a different scratch path to verify that
explicit product selection builds Core without native Zenoh. Graph snapshots
from SwiftPM 6.4 are in [`root-dependencies.txt`](root-dependencies.txt),
[`candidate-dependencies.txt`](candidate-dependencies.txt), and
[`candidate-target-graph.txt`](candidate-target-graph.txt). The root package
dependency list is unchanged; the candidate graph adds only the four local
targets shown in the patch, and the default build reaches the C façade.

## Public consumer checks

The #1042 external-consumer harness supports `AXOLOTY_CONSUMER_SCOPE=core-wire`.
For a fresh public URL resolution at an immutable commit, run:

```sh
AXOLOTY_CONSUMER_REVISION=0c74f3ae2328a8dc1528088f7b7d3be24f7cf241 \
AXOLOTY_CONSUMER_LOCAL=0 AXOLOTY_CONSUMER_SCOPE=core-wire \
make test-axoloty-semver-consumer
```

It creates independent `Axoloty`-only and `AxolotyWire`-only executables, then
builds and runs both in debug and release. Evidence includes their exact
manifest, resolved public URL/SHA, dependency graph, compiler logs, and run
markers. The public Core and Wire result is not synthesized from a local file
mirror.

For the experimental product, use `make test-tier TIER=zenoh-offline
NODE=zenoh-offline-package` to provision the pinned archive and run the
router-free package suite. A consumer outside the repository can then depend
on the checked-out `Packages/AxolotyZenoh` package by path, set
`PKG_CONFIG_PATH` to the provisioned `unpacked/lib/pkgconfig`, and set
`LD_LIBRARY_PATH` to `unpacked/lib`. The package path is an experimental
checkout workflow; the root Git URL cannot select this nested manifest.
