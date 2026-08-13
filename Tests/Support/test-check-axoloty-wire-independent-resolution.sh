#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$root/Tests/Support/check-axoloty-wire-independent-resolution.sh"
fake_bin=$(mktemp -d)
trap 'rm -rf "$fake_bin"' EXIT

cat >"$fake_bin/swift" <<'EOF'
#!/bin/sh
case "$*" in
    "package resolve") exit 0 ;;
    "package show-dependencies --format flatlist")
        printf '%s\n' axolotywire swift-json swift-nio swift-atomics swift-collections swift-system
        if [ "${AXOLOTY_FAKE_SWIFT_MODE:-}" = "fail-inspection" ]; then exit 42; fi
        if [ "${AXOLOTY_FAKE_SWIFT_MODE:-}" = "unexpected-dependency" ]; then
            printf '%s\n' "${AXOLOTY_FAKE_UNEXPECTED_DEPENDENCY:?}"
        fi
        exit 0
        ;;
    "build")
        if [ "${AXOLOTY_FAKE_SWIFT_MODE:-}" = "fail-build" ]; then exit 42; fi
        exit 0
        ;;
    *) echo "unexpected swift invocation: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$fake_bin/swift"

if AXOLOTY_FAKE_SWIFT_MODE=fail-inspection PATH="$fake_bin:$PATH" sh "$checker" >/dev/null 2>&1; then
    echo "expected independent-resolution check to fail when dependency inspection fails" >&2
    exit 1
fi

if AXOLOTY_FAKE_SWIFT_MODE=fail-build PATH="$fake_bin:$PATH" sh "$checker" >/dev/null 2>&1; then
    echo "expected independent-resolution check to fail when the fixture build fails" >&2
    exit 1
fi

if PATH="$fake_bin:$PATH" sh "$checker" >/dev/null 2>&1; then :; else
    echo "expected independent-resolution check to accept its allowlisted closure" >&2
    exit 1
fi

for unexpected_dependency in mqtt-nio new-package; do
    if AXOLOTY_FAKE_SWIFT_MODE=unexpected-dependency \
        AXOLOTY_FAKE_UNEXPECTED_DEPENDENCY="$unexpected_dependency" \
        PATH="$fake_bin:$PATH" sh "$checker" >/dev/null 2>&1; then
        echo "expected independent-resolution check to reject unexpected dependency: $unexpected_dependency" >&2
        exit 1
    fi
done
