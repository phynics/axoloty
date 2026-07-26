#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$root/Tests/Support/check-axoloty-wire-independent-resolution.sh"
fake_bin=$(mktemp -d)
trap 'rm -rf "$fake_bin"' EXIT

cat >"$fake_bin/swift" <<'EOF'
#!/bin/sh
if [ "${AXOLOTY_FAKE_SWIFT_MODE:-}" = "fail-build" ]; then
    case "$*" in
        "package resolve"|"package show-dependencies --format flat") exit 0 ;;
        "build") exit 42 ;;
        *) echo "unexpected swift invocation: $*" >&2; exit 1 ;;
    esac
else
    case "$*" in
        "package resolve") exit 0 ;;
        "package show-dependencies --format flat") exit 42 ;;
        *) echo "unexpected swift invocation: $*" >&2; exit 1 ;;
    esac
fi
EOF
chmod +x "$fake_bin/swift"

if PATH="$fake_bin:$PATH" sh "$checker" >/dev/null 2>&1; then
    echo "expected independent-resolution check to fail when dependency inspection fails" >&2
    exit 1
fi

if AXOLOTY_FAKE_SWIFT_MODE=fail-build PATH="$fake_bin:$PATH" sh "$checker" >/dev/null 2>&1; then
    echo "expected independent-resolution check to fail when the fixture build fails" >&2
    exit 1
fi
