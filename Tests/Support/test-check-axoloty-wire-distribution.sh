#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$root/Tests/Support/check-axoloty-wire-distribution.sh"

test -x "$checker"

fake_bin=$(mktemp -d)
trap 'rm -rf "$fake_bin"' EXIT

cat >"$fake_bin/swift" <<'EOF'
#!/bin/sh
case "$*" in
    "package resolve") exit 0 ;;
    "package show-dependencies --format flatlist")
        case "$PWD" in
            */root-consumer)
                if [ "${AXOLOTY_FAKE_SWIFT_MODE:-}" = "bad-root-resolution" ]; then
                    printf '%s\n' 'axoloty'
                else
                    printf '%s\n' 'axoloty mqtt-nio swift-nio ErrorKit'
                fi
                ;;
            *) printf '%s\n' 'AxolotyWire swift-json swift-nio' ;;
        esac
        ;;
    "build --configuration debug --target RootWireConsumer")
        if [ "${AXOLOTY_FAKE_SWIFT_MODE:-}" = "bad-root-build" ]; then
            printf '%s\n' 'Compiling NIOCore '
        fi
        ;;
    "run --configuration debug RootWireConsumer")
        if [ "${AXOLOTY_FAKE_SWIFT_MODE:-}" = "bad-root-runtime" ]; then
            printf '%s\n' 'unexpected marker'
        else
            printf '%s\n' 'AXOLOTY_WIRE_ROOT_CONSUMER_OK'
        fi
        ;;
    "build") exit 0 ;;
    "run --configuration debug DownstreamConsumer") printf '%s\n' 'AXOLOTY_WIRE_STANDALONE_CONSUMER_OK' ;;
    *) echo "unexpected swift invocation: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$fake_bin/swift"

PATH="$fake_bin:$PATH" sh "$checker"

for mode in bad-root-resolution bad-root-build bad-root-runtime; do
    if AXOLOTY_FAKE_SWIFT_MODE="$mode" PATH="$fake_bin:$PATH" sh "$checker" >/dev/null 2>&1; then
        echo "expected distribution checker to reject $mode" >&2
        exit 1
    fi
done

echo "AxolotyWire distribution checker validates both consumer topologies"
