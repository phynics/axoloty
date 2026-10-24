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
python3 - "$consumer_check" "$work" <<'PY'
import re
import sys
from pathlib import Path

consumer_path = Path(sys.argv[1])
work_path = Path(sys.argv[2])
consumer_text = consumer_path.read_text(encoding="utf-8")
heredoc_header = 'cat >"$consumer/Sources/TransportSPIConsumer/main.swift" <<\'EOF\'\n'
header_index = consumer_text.find(heredoc_header)
if header_index < 0 or consumer_text.find(heredoc_header, header_index + 1) >= 0:
    raise SystemExit("diagnostic fixture extraction failed: expected one TransportSPIConsumer heredoc")
fixture_start = header_index + len(heredoc_header)
fixture_end = consumer_text.find("\nEOF\n", fixture_start)
if fixture_end < 0:
    raise SystemExit("diagnostic fixture extraction failed: missing TransportSPIConsumer heredoc terminator")
fixture = consumer_text[fixture_start:fixture_end]

required_assertions = (
    "runtime.diagnosticsSnapshot()",
    "runtime.diagnostics()",
    "initialDiagnostics.lifecycleState == .running",
    "initialCapabilities.wireProfile == .coaty3JSON",
    "initialCapabilities.protocolCapabilities.isCoatyCore3",
    "initialCapabilities.transportCapabilities == transport.capabilities",
    "initialDiagnostics.diagnosticCapacity > 0",
    "initialDiagnostics.diagnosticCapacity == initialCapabilities.diagnosticCapacity",
    "initialCapabilities.maximumPayloadBytes > 0",
    "initialCapabilities.maximumObjects > 0",
    "initialCapabilities.maximumPendingCorrelations > 0",
    "receipt == .rejected(.malformedPayload)",
    "afterRejectedRequest.rejectedRequests == beforeRejectedRequest.rejectedRequests + 1",
    "afterRejectedRequest.diagnosticsEmitted > beforeRejectedRequest.diagnosticsEmitted",
    "afterRejectedRequest.diagnosticSequence > beforeRejectedRequest.diagnosticSequence",
    "diagnostic.kind == .requestRejected",
    "rejectedDiagnostic.sequence > beforeRejectedRequest.diagnosticSequence",
    "if case .request(let observation)? = rejectedDiagnostic.observation",
    "observation.correlationID == correlationID",
    "observation.outcome == .rejected",
    "observation.rejection == .malformedPayload",
    "guard started, initialDiagnosticsValid, rejectionMatches,",
    "finalDiagnostics.lifecycleState == .stopped",
    "withThrowingTaskGroup",
    "async throws(ConsumerFailure)",
    "try await Task.sleep(for: .seconds(5))",
    "defer { group.cancelAll() }",
)
sequence_assertion = "rejectedDiagnostic.sequence > beforeRejectedRequest.diagnosticSequence"
diagnostic_marker = "AXOLOTY_DIAGNOSTIC_CONSUMER_BEHAVIOR_OK rejection=malformedPayload sequence="


class FixtureSyntaxError(Exception):
    pass


def strip_fixture_comments(source):
    """Mask comments and strings in this ordinary-string Swift fixture subset."""
    output = []
    strings = []
    index = 0

    def masked(segment):
        return "".join("\n" if char == "\n" else " " for char in segment)

    while index < len(source):
        if source.startswith("//", index):
            end = source.find("\n", index)
            if end < 0:
                end = len(source)
            output.append(masked(source[index:end]))
            index = end
            continue

        if source.startswith("/*", index):
            start = index
            depth = 1
            index += 2
            while index < len(source) and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            if depth:
                raise FixtureSyntaxError("unterminated Swift block comment")
            output.append(masked(source[start:index]))
            continue

        if source[index] == "/":
            raise FixtureSyntaxError("unsupported slash syntax outside a comment")

        if source[index] == '"':
            if source.startswith('"""', index) or (index > 0 and source[index - 1] == "#"):
                raise FixtureSyntaxError("unsupported multiline or raw Swift string syntax")
            start = index
            index += 1
            while index < len(source):
                char = source[index]
                if char == "\\":
                    if index + 1 >= len(source):
                        raise FixtureSyntaxError("unterminated Swift string escape")
                    if source[index + 1] == "(":
                        index += 2
                        depth = 1
                        while index < len(source) and depth:
                            if source.startswith(("//", "/*"), index) or source[index] == '"':
                                raise FixtureSyntaxError("unsupported comment or string inside interpolation")
                            if source[index] == "(":
                                depth += 1
                            elif source[index] == ")":
                                depth -= 1
                            index += 1
                        if depth:
                            raise FixtureSyntaxError("unterminated Swift string interpolation")
                    else:
                        index += 2
                    continue
                if char == '"':
                    content = source[start + 1:index]
                    string_index = len(strings)
                    strings.append(content)
                    output.append(f"__SWIFT_STRING_{string_index}__")
                    index += 1
                    break
                if char == "\n":
                    raise FixtureSyntaxError("unsupported newline in ordinary Swift string")
                index += 1
            else:
                raise FixtureSyntaxError("unterminated ordinary Swift string")
            continue

        output.append(source[index])
        index += 1

    return "".join(output), strings


def check_fixture(path):
    text = path.read_text(encoding="utf-8")
    header = text.find(heredoc_header)
    if header < 0 or text.find(heredoc_header, header + 1) >= 0:
        return "TransportSPIConsumer fixture extraction"
    start = header + len(heredoc_header)
    end = text.find("\nEOF\n", start)
    if end < 0:
        return "TransportSPIConsumer fixture extraction"
    body = text[start:end]
    try:
        code, literals = strip_fixture_comments(body)
    except FixtureSyntaxError as error:
        return f"Swift fixture syntax ({error})"
    for assertion in required_assertions:
        if assertion not in code:
            return assertion
    marker_printed = any(
        literal.startswith(diagnostic_marker)
        and re.search(rf"\bprint\s*\(\s*__SWIFT_STRING_{literal_index}__\s*\)", code)
        for literal_index, literal in enumerate(literals)
    )
    if not marker_printed:
        return "TransportSPIConsumer Swift diagnostic success marker string"
    return None


original_path = consumer_path
original_failure = check_fixture(original_path)
if original_failure:
    raise SystemExit(f"consumer fixture omitted required diagnostic assertion: {original_failure}")
print("original TransportSPIConsumer fixture assertions: pass")

line = "            && " + sequence_assertion
if fixture.count(line) != 1:
    raise SystemExit("diagnostic fixture mutation setup failed: stream sequence assertion is not unique")
mutations = {
    "line-commented": fixture.replace(line, "            // && " + sequence_assertion, 1),
    "multiline-block": fixture.replace(line, "            /*\n" + line + "\n            */", 1),
    "nested-block": fixture.replace(line, "            /* outer /* inner */\n" + line + "\n            */", 1),
    "same-line-block": fixture.replace(line, "            /* " + line.strip() + " */", 1),
    "removed": fixture.replace(line + "\n", "", 1),
}
quoted_probe = r'        let commentDelimiterProbe = "escaped quote: \"; fake assertion: /* ' + sequence_assertion + r' */ // still string content"' + "\n"
quoted_probe_fixture = fixture.replace(line + "\n", "", 1)
quoted_probe_fixture = quoted_probe_fixture.replace("import Foundation\n", "import Foundation\n" + quoted_probe, 1)
mutations["quoted-comment-delimiters"] = quoted_probe_fixture
for name, mutated_fixture in mutations.items():
    mutation_path = work_path / f"consumer-fixture-mutation-{name}.sh"
    mutation_path.write_text(consumer_text[:fixture_start] + mutated_fixture + consumer_text[fixture_end:], encoding="utf-8")
    failure = check_fixture(mutation_path)
    if failure != sequence_assertion:
        raise SystemExit(f"mutation {name} failed unexpectedly: expected named diagnostic {sequence_assertion!r}, got {failure!r}")
    print(f"mutation {name}: rejected by diagnostic {sequence_assertion!r}")
PY
grep -Fq "grep -Eq '^AXOLOTY_DIAGNOSTIC_CONSUMER_BEHAVIOR_OK rejection=malformedPayload sequence=" "$consumer_check" || {
    echo "consumer harness does not require the diagnostic success marker" >&2
    exit 1
}
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


wire_log="$work/wire-build.log"
printf '[51 / 58] AxolotyWire\n[63 / 63] WireConsumer-product\n' >"$wire_log"
axoloty_check_wire_build_isolation "$wire_log"
for host_line in '[42 / 58] NIOCore' '[11/20] CNIOBoringSSL' '[7/20] _NIOBase64-product' '[4/5] MQTTNIO-product' '[1/2] Compiling Logging Logger.swift' 'Compiling ErrorKit Error.swift'; do
    printf '%s\n' "$host_line" >"$wire_log"
    if axoloty_check_wire_build_isolation "$wire_log" >/dev/null 2>&1; then
        echo "expected host-module rejection: $host_line" >&2
        exit 1
    fi
done
if axoloty_check_wire_build_isolation "$work/missing-log" >/dev/null 2>&1; then
    echo "expected missing Wire build-log rejection" >&2
    exit 1
fi

echo "external consumer provenance checks reject noncanonical URLs, paths, and mismatched Core pins"
