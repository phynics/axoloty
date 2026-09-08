// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const root = path.resolve(new URL("../../..", import.meta.url).pathname);
const runnerPath = path.join(root, "Tests/Support/WireCompatibility/Live/run-mqtt-binding-network.sh");
const runner = fs.readFileSync(runnerPath, "utf8");

test("MQTT binding runner is bounded, diagnostic, and ownership-scoped", () => {
  assert.equal(spawnSync("bash", ["-n", runnerPath], { encoding: "utf8" }).status, 0);
  for (const marker of [
    "DEADLINE_SECONDS=",
    "runtime_bounded()",
    "wait_for()",
    "collect_diagnostics()",
    "runtime logs \"$SUBJECT\"",
    "runtime rm -f \"$SUBJECT\" \"$PROBE\" \"$BROKER\"",
    "io.axoloty.managed-by=",
    "io.axoloty.run-id=",
    "io.axoloty.scenario=",
    "WIRE_MQTT_BINDING_RESTARTED",
    "WIRE_MQTT_BINDING_RESUBSCRIBE_READY",
  ]) {
    assert.ok(runner.includes(marker), `runner is missing ${marker}`);
  }
  assert.match(runner, /test -s "\$APPLICATION_LOG"/);
  assert.match(runner, /test -s "\$CAPTURE"/);
  assert.match(runner, /grep -q .*state/);
  assert.doesNotMatch(runner, /run -d[^\n]*--rm/);
});

test("MQTT binding runner rejects an unavailable runtime without creating artifacts outside its output", () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-mqtt-binding-runner-"));
  const fakeRuntime = path.join(temporary, "runtime");
  const output = path.join(temporary, "output");
  fs.writeFileSync(fakeRuntime, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$FAKE_RUNTIME_LOG\"\nexit 17\n");
  fs.chmodSync(fakeRuntime, 0o755);
  try {
    const result = spawnSync("bash", [runnerPath], {
      cwd: root,
      encoding: "utf8",
      env: {
        ...process.env,
        CONTAINER_RUNTIME: fakeRuntime,
        FAKE_RUNTIME_LOG: path.join(temporary, "runtime.log"),
        WIRE_OUTPUT_DIR: output,
        WIRE_RUN_ID: "mqtt-binding-self-test",
        WIRE_MQTT_BINDING_DEADLINE_SECONDS: "1",
      },
    });
    assert.equal(result.status, 17, `${result.stdout}\n${result.stderr}`);
    assert.match(fs.readFileSync(path.join(temporary, "runtime.log"), "utf8"), /network create/);
    assert.match(fs.readFileSync(path.join(temporary, "runtime.log"), "utf8"), /io\.axoloty\.run-id=mqtt-binding-self-test/);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});
