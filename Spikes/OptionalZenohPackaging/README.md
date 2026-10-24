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

Use the repository's pinned image and private build/cache directories. This
command checks native absence, then runs both candidate builds. It retains
separate stdout, stderr, and exit-code files under the host `BUILD_DIR`; the
default build is expected to fail, so the wrapper records its status and
continues to the explicit Core build:

```sh
flock /tmp/axoloty-batch2-382c4846/verification.lock \
  env CONTAINER_RUNTIME="$(command -v podman)" IMAGE=axoloty-dev \
  BUILD_DIR=/tmp/axoloty-1001-build SPM_CACHE_DIR=/tmp/axoloty-1001-spm \
  BUILD_LOCK=0 .devcontainer/run.sh bash -euo pipefail -c '
    candidate=/workspace/.testing/runs/optional-zenoh-1001/rerun-candidate
    out=/workspace/.build/optional-zenoh-1001/candidate-replay
    mkdir -p "$out"
    cd "$candidate"
    {
      env | sort | rg "^(PKG_CONFIG_PATH|PKG_CONFIG_LIBDIR|CPATH|C_INCLUDE_PATH|LIBRARY_PATH|LD_LIBRARY_PATH)=" || true
      if pkg-config --exists zenohc; then echo "unexpected zenohc" >&2; exit 90; else echo "pkg-config cannot resolve zenohc"; fi
      test ! -e /usr/include/zenoh.h && test ! -e /usr/local/include/zenoh.h
      echo "no zenoh.h under /usr/include or /usr/local/include"
      if find /usr/lib /usr/local/lib -maxdepth 5 \( -iname zenohc.pc -o -iname "libzenohc.so*" -o -iname libzenohc.a \) -print -quit | rg -q .; then exit 91; fi
      echo "no zenohc.pc or libzenohc under /usr/lib or /usr/local/lib"
      if ldconfig -p 2>/dev/null | rg -qi libzenohc; then exit 92; fi
      echo "ldconfig has no libzenohc entry"
    } >"$out/native-absence.stdout" 2>"$out/native-absence.stderr"
    run_build() {
      name=$1; shift
      set +e
      env -u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR -u CPATH -u C_INCLUDE_PATH -u LIBRARY_PATH -u LD_LIBRARY_PATH swift build --cache-path /workspace/.swiftpm-cache --scratch-path "$out/$name-scratch" --disable-automatic-resolution "$@" >"$out/$name.stdout" 2>"$out/$name.stderr"
      status=$?
      set -e
      printf '%s\n' "$status" >"$out/$name.exit"
    }
    run_build default
    run_build explicit-core --product Axoloty
    test "$(cat "$out/default.exit")" -ne 0
    test "$(cat "$out/explicit-core.exit")" -eq 0
  '
```

The default build is expected to fail in `CAxolotyZenoh` with `zenoh.h` not
found; the explicit `Axoloty` build should pass without native Zenoh. Graph snapshots
from SwiftPM 6.4 are in [`root-dependencies.txt`](root-dependencies.txt),
[`candidate-dependencies.txt`](candidate-dependencies.txt), and
[`candidate-target-graph.txt`](candidate-target-graph.txt). The root package
dependency list is unchanged; the candidate graph adds only the four local
targets shown in the patch, and the default build reaches the C façade. For
review-round captures and exact artifact hashes, see
[`review-round1-evidence.md`](review-round1-evidence.md). A rerun against an
existing SwiftPM cache is a cached rerun, not a fresh original execution;
preserve that distinction in any new evidence index.

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
