// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const supportDirectory = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const wireDirectory = path.join(supportDirectory, "WireCompatibility");
const helper = path.join(wireDirectory, "container-wait.sh");

// `podman wait` prints the exit status and exits 0 whatever it is, so the fake
// runtime reproduces that and lets each case choose what it prints and returns.
const fakeRuntime = `#!/usr/bin/env bash
echo "$*" >>"$FAKE_RUNTIME_LOG"
case "$1" in
    wait) sleep "\${FAKE_WAIT_SLEEP:-0}"; printf '%b' "\${FAKE_WAIT_OUTPUT-0\\n}"; exit "\${FAKE_WAIT_RC:-0}" ;;
    logs) echo "FAKE-CONTAINER-LOG" ;;
esac
`;

function waitFor(environment) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "container-wait-"));
  try {
    const runtime = path.join(temporary, "runtime");
    fs.writeFileSync(runtime, fakeRuntime, { mode: 0o755 });
    const log = path.join(temporary, "runtime.log");
    const result = spawnSync(
      "bash",
      ["-c", `RUNTIME="${runtime}"; source "${helper}"; wait_for_success subject; echo "rc=$?"`],
      { encoding: "utf8", env: { ...process.env, FAKE_RUNTIME_LOG: log, ...environment } },
    );
    const calls = fs.existsSync(log) ? fs.readFileSync(log, "utf8") : "";
    return { ...result, calls, rc: Number(/rc=(\d+)/.exec(result.stdout)?.[1]) };
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

test("a zero exit status succeeds without dumping the log", () => {
  const result = waitFor({ FAKE_WAIT_OUTPUT: "0\n" });
  assert.equal(result.rc, 0);
  assert.doesNotMatch(result.stderr, /FAKE-CONTAINER-LOG/);
});

for (const [name, environment, pattern] of [
  ["a nonzero exit status", { FAKE_WAIT_OUTPUT: "1\n" }, /exited with status 1/],
  ["a signal exit status", { FAKE_WAIT_OUTPUT: "137\n" }, /exited with status 137/],
  ["an empty status", { FAKE_WAIT_OUTPUT: "" }, /non-numeric exit status/],
  ["a nonnumeric status", { FAKE_WAIT_OUTPUT: "Error: no such container\n" }, /non-numeric exit status/],
  ["a failed wait command", { FAKE_WAIT_OUTPUT: "0\n", FAKE_WAIT_RC: "125" }, /failed with status 125/],
]) {
  test(`${name} fails and shows the container log`, () => {
    const result = waitFor(environment);
    assert.equal(result.rc, 1);
    assert.match(result.stderr, pattern);
    assert.match(result.stderr, /FAKE-CONTAINER-LOG/);
  });
}

test("a timeout returns 124, shows the log, and stops the container", () => {
  const result = waitFor({ FAKE_WAIT_SLEEP: "5", WIRE_CONTAINER_WAIT_SECONDS: "1" });
  assert.equal(result.rc, 124);
  assert.match(result.stderr, /did not exit within 1s/);
  assert.match(result.stderr, /FAKE-CONTAINER-LOG/);
  assert.match(result.calls, /^stop -t 1 subject$/m);
  assert.match(result.calls, /^kill subject$/m);
});

// Returns the lines that wait on a container through any runtime spelling the
// scripts use, without reading the printed status. It joins backslash
// continuations first and skips comment lines. The runtime may be quoted
// ("$RUNTIME"), braced (${RUNTIME}), a wrapper function, or a literal CLI name,
// and may be preceded by `timeout 120s` or followed by options.
const runtimeWord = String.raw`(?:"?\$\{?(?:CONTAINER_)?RUNTIME\}?"?|runtime_bounded|runtime|podman|docker)`;
const bareWait = new RegExp(String.raw`(?<![\w$./-])${runtimeWord}\s+(?:-\S+\s+)*wait(?![\w-])`);

export function findBareWaits(text) {
  return text
    .replace(/\\\r?\n\s*/g, " ")
    .split("\n")
    .filter((line) => !line.trimStart().startsWith("#"))
    .filter((line) => bareWait.test(line));
}

test("the bare-wait guard recognizes every runtime spelling", () => {
  for (const line of [
    'runtime wait "$SUBJECT"',
    'if ! runtime_bounded wait "$CONSUMER" >/dev/null; then',
    '"$RUNTIME" wait "$SUBJECT" >/dev/null',
    '"${RUNTIME}" wait "$SUBJECT"',
    '$RUNTIME wait "$SUBJECT"',
    '${RUNTIME} wait "$SUBJECT"',
    '"$CONTAINER_RUNTIME" wait "$SUBJECT"',
    'timeout 120s "$RUNTIME" wait "$SUBJECT"',
    'timeout "${WIRE_CONTAINER_WAIT_SECONDS:-120}s" podman wait "$SUBJECT"',
    'podman wait "$SUBJECT" >/dev/null',
    'docker wait "$SUBJECT"',
    'podman  wait   "$SUBJECT"',
    'podman --remote wait "$SUBJECT"',
    'status=$(podman wait "$SUBJECT")',
    'runtime_bounded \\\n    wait "$SUBJECT"',
    '"$RUNTIME" \\\n  wait "$SUBJECT" >/dev/null',
    'runtime_bounded \\\r\n\twait "$SUBJECT"',
  ]) {
    assert.equal(findBareWaits(line).length, 1, `should reject: ${JSON.stringify(line)}`);
  }
});

test("the bare-wait guard accepts the shared helper and unrelated text", () => {
  for (const line of [
    'wait_for_success "$SUBJECT" || exit 1',
    "# runtime wait is documented here",
    'wait "$pid" >/dev/null 2>&1 || true',
    'runtime logs "$SUBJECT" >"$RAW_LOG"',
    'runtime_bounded run --rm --network "$NETWORK" wait-image',
    'wait_for "subject reconnect" "subject_reported reconnected"',
  ]) {
    assert.equal(findBareWaits(line).length, 0, `should accept: ${JSON.stringify(line)}`);
  }
});

test("no live script waits on a container without reading its status", () => {
  const scripts = [];
  const visit = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (entry.name === "node_modules") continue;
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(entryPath);
      else if (entry.name.endsWith(".sh") && entry.name !== "container-wait.sh") scripts.push(entryPath);
    }
  };
  visit(wireDirectory);
  // probe-broker-signals.sh waits for a SIGTERM'd broker and asserts the
  // `exited` state instead of a status, which is not a pass/fail signal.
  const exempt = new Set(["probe-broker-signals.sh"]);
  const offenders = scripts
    .filter((script) => !exempt.has(path.basename(script)))
    .flatMap((script) =>
      findBareWaits(fs.readFileSync(script, "utf8")).map((line) => `${path.relative(wireDirectory, script)}: ${line.trim()}`),
    );
  assert.deepEqual(offenders, [], "these scripts discard the container exit status");
  const probe = fs.readFileSync(path.join(wireDirectory, "Lifecycle/Live/probe-broker-signals.sh"), "utf8");
  assert.equal(findBareWaits(probe).length, 1, "the exemption should still be needed");
});
