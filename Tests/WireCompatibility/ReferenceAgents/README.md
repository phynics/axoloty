# Wire compatibility reference agents

The compatibility suite treats published releases as protocol oracles. Pins are
kept in `versions.env`; update them only as a reviewed compatibility decision.

## Selected references

| Implementation | Release | Immutable source | Distribution |
|---|---|---|---|
| CoatyJS | `@coaty/core@2.4.0` | `coatyio/coaty-js` `4a7716815f9f775db812e7a079146e56e08570d1` (`v2.4.0`) | npm integrity recorded in `versions.env` |
| Legacy Swift | CoatySwift `2.4.0` | `coatyio/coaty-swift` `20a97b29832758fb771ac79fd5f7ae36cff69403` (tag `2.4.0`, with no `v` prefix) | source tag |

CoatyJS 2.4.0 was selected because it is the same protocol-generation release
as the legacy Swift baseline. Its Node agent is reproducible: the npm package,
RxJS peer dependency, package lock, and Linux/amd64 Node image are pinned.

## CoatyJS runner

Build and invoke it from this directory:

```sh
podman build -t coatyswift-wire-coatyjs coatyjs
podman run --rm --network host \
  -e BROKER_URL=mqtt://127.0.0.1:1883 \
  -e SCENARIO=advertise \
  coatyswift-wire-coatyjs
```

The runner emits one JSON status record per line. `ready` means it has created
the reference container; `published` identifies the deterministic fixture
object; `done` means it shut down cleanly. The currently supported scenario is
`advertise`. T-019 extends this runner with the live core matrix.

## Legacy Swift constraint

CoatySwift 2.4.0 cannot be made into a truthful Linux reference-agent image.
Its MQTT dependency contains Objective-C sources importing Apple Foundation,
which does not exist in Linux Swift images. Patching that dependency would
change the reference implementation and invalidate it as an oracle. Apple does
not provide macOS container images.

The `legacy-swift` directory therefore records and verifies the immutable
source pin plus the same scenario interface, but deliberately does not claim a
Linux container. Execute its runner on a macOS host/Xcode runner, or capture
fixtures from such a runner and replay them on Linux. The macOS implementation
is the remaining acceptance item before T-017 can be considered fully closed.

## Pin verification

`./verify-pins.sh` performs read-only checks against GitHub and npm. It requires
network access and reports an error if a tag or package integrity hash moves.
