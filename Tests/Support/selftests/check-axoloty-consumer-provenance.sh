#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$root/Tests/Support/lib/consumer-provenance.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Exercise the production URL gate with command spies. Invalid and canonical
# URLs must be decided before SwiftPM resolution or any build starts.
consumer_check="$root/Tests/Support/checks/check-axoloty-semver-consumer.sh"
spy_bin="$work/bin"
mkdir -p "$spy_bin"
cat >"$spy_bin/swift" <<'EOF'
#!/bin/sh
if [ "${AXOLOTY_CONSUMER_EXPECTED_HOME+x}" = x ] && [ "${HOME-}" != "$AXOLOTY_CONSUMER_EXPECTED_HOME" ]; then
    echo unexpected-home >>"$AXOLOTY_CONSUMER_SPY_MARKER"
    exit 91
fi
printf '%s\n' "$*" >>"$AXOLOTY_CONSUMER_SPY_MARKER"
[ "$*" = --version ] && { echo 'Swift fixture'; exit 0; }
exit 90
EOF
cp "$spy_bin/swift" "$spy_bin/git"
chmod +x "$spy_bin/swift" "$spy_bin/git"

localhost_evidence="$work/localhost-evidence"
localhost_marker="$work/localhost-command-marker"
if output=$(env PATH="$spy_bin:$PATH" \
    AXOLOTY_CONSUMER_LOCAL=0 \
    AXOLOTY_CONSUMER_REVISION=6f34bcc1fa77da35d23303c51cbfc9a96e583d10 \
    AXOLOTY_CONSUMER_REPOSITORY_URL=https://localhost/axoloty.git \
    AXOLOTY_CONSUMER_EVIDENCE_DIR="$localhost_evidence" \
    AXOLOTY_CONSUMER_SPY_MARKER="$localhost_marker" \
    sh "$consumer_check" 2>&1); then
    echo "expected localhost consumer URL rejection" >&2
    exit 1
fi
case "$output" in
    *"non-synthetic consumer validation requires canonical repository URL: https://github.com/phynics/axoloty.git"*) : ;;
    *) echo "localhost rejection did not identify the canonical repository requirement: $output" >&2; exit 1 ;;
esac
[ ! -e "$localhost_marker" ] || { echo "localhost URL reached git or SwiftPM" >&2; exit 1; }
[ ! -e "$localhost_evidence" ] || { echo "localhost URL created evidence before rejection" >&2; exit 1; }

canonical_evidence="$work/canonical-evidence"
canonical_marker="$work/canonical-command-marker"
if output=$(env PATH="$spy_bin:$PATH" \
    AXOLOTY_CONSUMER_LOCAL=0 \
    AXOLOTY_CONSUMER_REVISION=6f34bcc1 \
    AXOLOTY_CONSUMER_REPOSITORY_URL=https://github.com/phynics/axoloty.git \
    AXOLOTY_CONSUMER_EVIDENCE_DIR="$canonical_evidence" \
    AXOLOTY_CONSUMER_SPY_MARKER="$canonical_marker" \
    sh "$consumer_check" 2>&1); then
    echo "expected short canonical revision rejection before resolution" >&2
    exit 1
fi
case "$output" in
    *"AXOLOTY_CONSUMER_REVISION must contain 40 hex characters"*) : ;;
    *) echo "canonical URL did not pass the URL gate: $output" >&2; exit 1 ;;
esac
[ ! -e "$canonical_marker" ] || { echo "canonical preflight test reached git or SwiftPM" >&2; exit 1; }
[ ! -e "$canonical_evidence" ] || { echo "canonical preflight test created evidence before revision validation" >&2; exit 1; }

# A valid canonical request reaches resolution with explicit private state
# paths while preserving HOME. The Swift spy stops before network access.
canonical_marker="$work/canonical-resolution-marker"
if output=$(env PATH="$spy_bin:$PATH" \
    AXOLOTY_CONSUMER_LOCAL=0 \
    AXOLOTY_CONSUMER_REVISION=6f34bcc1fa77da35d23303c51cbfc9a96e583d10 \
    AXOLOTY_CONSUMER_REPOSITORY_URL=https://github.com/phynics/axoloty.git \
    AXOLOTY_CONSUMER_EVIDENCE_DIR="$work/canonical-resolution-evidence" \
    AXOLOTY_CONSUMER_EXPECTED_HOME="${HOME-}" \
    AXOLOTY_CONSUMER_SPY_MARKER="$canonical_marker" \
    sh "$consumer_check" 2>&1); then
    echo "expected Swift spy to stop canonical resolution" >&2
    exit 1
fi
grep -Eq '^package --config-path /.+/configuration --cache-path /.+/cache --security-path /.+/security resolve$' "$canonical_marker" || {
    echo "canonical resolution did not use explicit private SwiftPM paths: $output" >&2
    exit 1
}
if grep -Fqx unexpected-home "$canonical_marker"; then
    echo "consumer validation changed HOME" >&2
    exit 1
fi

consumer="$work/consumer"
mkdir -p "$consumer/Sources/Consumer"
cat >"$consumer/Package.swift" <<'EOF'
// swift-tools-version:6.4
import PackageDescription
let package = Package(name: "Consumer", dependencies: [.package(url: "https://github.com/phynics/axoloty.git", revision: "6f34bcc1fa77da35d23303c51cbfc9a96e583d10")], targets: [])
EOF
printf 'print("ok")\n' >"$consumer/Sources/Consumer/main.swift"
axoloty_check_consumer_paths "$root" "$consumer"

cat >"$consumer/Package.swift" <<EOF
let package = Package(dependencies: [.package(path: "$root")])
EOF
if axoloty_check_consumer_paths "$root" "$consumer" >/dev/null 2>&1; then
    echo "expected path-dependency rejection" >&2
    exit 1
fi

cat >"$consumer/Package.swift" <<'EOF'
let package = Package(name: "Consumer", dependencies: [.package(url: "https://github.com/phynics/axoloty.git", revision: "6f34bcc1fa77da35d23303c51cbfc9a96e583d10")], targets: [])
EOF
printf 'let checkout = "%s"\n' "$root" >"$consumer/Sources/Consumer/main.swift"
if axoloty_check_consumer_paths "$root" "$consumer" >/dev/null 2>&1; then
    echo "expected incidental repository-path rejection" >&2
    exit 1
fi

resolved="$work/Package.resolved"
cat >"$resolved" <<'EOF'
{"pins":[{"identity":"axoloty","kind":"remoteSourceControl","location":"https://github.com/phynics/axoloty.git","state":{"revision":"6f34bcc1fa77da35d23303c51cbfc9a96e583d10"}}]}
EOF
axoloty_check_core_pin "$resolved" https://github.com/phynics/axoloty.git 6f34bcc1fa77da35d23303c51cbfc9a96e583d10
if axoloty_check_core_pin "$resolved" https://github.com/phynics/axoloty.git 1111111111111111111111111111111111111111 >/dev/null 2>&1; then
    echo "expected mismatched resolved revision rejection" >&2
    exit 1
fi

echo "external consumer provenance checks reject noncanonical URLs, paths, and mismatched Core pins"
