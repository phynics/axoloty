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

test("no live script waits on a container without reading its status", () => {
  const scripts = [];
  const visit = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (entry.name === "node_modules") continue;
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(entryPath);
      else if (entry.name.endsWith(".sh") && !["container-wait.sh"].includes(entry.name)) scripts.push(entryPath);
    }
  };
  visit(wireDirectory);
  // probe-broker-signals.sh waits for a SIGTERM'd broker and asserts the
  // `exited` state instead of a status, which is not a pass/fail signal.
  const exempt = new Set(["probe-broker-signals.sh"]);
  for (const script of scripts.filter((s) => !exempt.has(path.basename(s)))) {
    const text = fs.readFileSync(script, "utf8");
    assert.doesNotMatch(
      text,
      /(runtime|runtime_bounded|podman|docker|\$RUNTIME)\s+wait\s/,
      `${path.relative(wireDirectory, script)} discards the container exit status`,
    );
  }
});
