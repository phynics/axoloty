// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const runScript = fs.readFileSync(".devcontainer/run.sh", "utf8");

test("run.sh builds an owned, run-scoped container command", () => {
  assert.match(runScript, /container_run_id=\$\{AXOLOTY_RUN_ID/);
  assert.match(runScript, /container_name=\$\{CONTAINER_NAME/);
  assert.match(runScript, /--name "\$container_name"/);
  assert.match(runScript, /--label io\.axoloty\.managed-by=axoloty-run\.sh/);
  assert.match(runScript, /--label "io\.axoloty\.run-id=\$container_run_id"/);
  assert.match(runScript, /"\$runtime" create/);
  assert.match(runScript, /--cidfile "\$container_cidfile"/);
  assert.match(runScript, /container_has_expected_labels/);
  assert.match(runScript, /"\$runtime" start --attach/);
  assert.match(runScript, /CONTAINER_CREATE_TIMEOUT_SECONDS:-120/);
  assert.match(runScript, /container_started=1/);
  assert.doesNotMatch(runScript, /confirm_container_ownership/);
  assert.doesNotMatch(runScript, /wait_for_ownership/);
  assert.match(runScript, /io\.axoloty\.worktree/);
  assert.match(runScript, /io\.axoloty\.owner/);
  assert.match(runScript, /io\.axoloty\.instance/);
  assert.match(runScript, /wait_for_process_completion "\$container_pid"/);
  assert.match(runScript, /terminate_process_tree_bounded/);
});

test("run.sh forwards signals and cleans only a matching owned container", () => {
  assert.match(runScript, /trap cleanup EXIT/);
  assert.match(runScript, /trap 'forward_signal INT' INT/);
  assert.match(runScript, /trap 'forward_signal TERM' TERM/);
  assert.match(runScript, /--format '\{\{\.Id\}\}\|\{\{ index \.Config\.Labels/);
  assert.match(runScript, /owned_labels=/);
  assert.match(runScript, /io\.axoloty\.run-id/);
  assert.match(runScript, /stop --time "\$container_term_grace"/);
  assert.match(runScript, /kill "\$container_id"/);
  assert.match(runScript, /rm -f "\$container_id"/);
  assert.doesNotMatch(runScript, /runtime run \\\n+.*--rm/);
});

test("run.sh retains existing optional runtime boundaries", () => {
  for (const marker of [
    "CONTAINER_DEVICES",
    "CONTAINER_OPTIONAL_DEVICES",
    "env_file=$(mktemp",
    "AXOLOTY_HOST_RUNTIME_BRIDGE",
    "CONTAINER_RECLAIM_BUILD_DIR",
    "--security-opt label=disable",
  ]) {
    assert.ok(runScript.includes(marker), `missing runtime boundary: ${marker}`);
  }
});

test("run.sh gates Podman relabeling and applies the lease policy", () => {
  assert.match(runScript, /CONTAINER_MOUNT_SUFFIX\+x/);
  assert.match(runScript, /\/sys\/fs\/selinux\/enforce/);
  assert.match(runScript, /selinux_labeling_active=1/);
  assert.match(runScript, /device_lease_mount_suffix=:z/);
});

test("live lifecycle matrix reaps a TERM-ignoring child and retains its final diagnostic", (t) => {
  const root = path.resolve(".");
  const matrixScript = path.join(root, "Tests/Support/WireCompatibility/Lifecycle/Live/run-lifecycle-matrix.sh");
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-wire-lifecycle-"));
  const runner = path.join(temporary, "hostile-runner.sh");
  const leaderExitsRunner = path.join(temporary, "leader-exits-runner.sh");
  const fastRunner = path.join(temporary, "fast-runner.sh");
  const runtime = path.join(temporary, "fake-runtime");
  const runtimeLog = path.join(temporary, "runtime.log");
  const output = path.join(temporary, "run");

  fs.writeFileSync(runner, `#!/usr/bin/env bash
set -u
scenario="$1"
printf 'HOSTILE-START scenario=%s pid=%s\\n' "$scenario" "$$"
(sleep 1000) &
descendant="$!"
printf '%s\\n' "$descendant" > "\${WIRE_OUTPUT_DIR}/hostile-descendant.pid"
trap 'printf "FINAL-DIAGNOSTIC scenario=%s pid=%s\\n" "$scenario" "$$"; trap - TERM INT; while :; do sleep 0.1 || :; done' TERM INT
while :; do sleep 0.1 || :; done
`);
  fs.chmodSync(runner, 0o755);
  fs.writeFileSync(leaderExitsRunner, `#!/usr/bin/env bash
set -u
scenario="$1"
(trap '' TERM; while :; do sleep 0.1 || :; done) &
descendant="$!"
printf '%s\\n' "$descendant" > "\${WIRE_OUTPUT_DIR}/hostile-descendant.pid"
trap 'printf "FINAL-DIAGNOSTIC scenario=%s pid=%s\\n" "$scenario" "$$"; exit 0' TERM
while :; do sleep 0.1 || :; done
`);
  fs.chmodSync(leaderExitsRunner, 0o755);
  fs.writeFileSync(fastRunner, "#!/usr/bin/env bash\nexit 0\n");
  fs.chmodSync(fastRunner, 0o755);
  // The matrix only queries this runtime in the self-test. Returning no
  // objects proves that cleanup is label-scoped without starting a broker or
  // touching a real container runtime.
  fs.writeFileSync(runtime, `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "\${FAKE_RUNTIME_LOG}"
exit 0
`);
  fs.chmodSync(runtime, 0o755);

  const started = Date.now();
  const matrixEnvironment = {
    ...process.env,
    PATH: `${temporary}:${process.env.PATH ?? ""}`,
    CONTAINER_RUNTIME: "fake-runtime",
    FAKE_RUNTIME_LOG: runtimeLog,
    WIRE_LIFECYCLE_RUN_DIR: output,
    WIRE_RUN_ID: "hostile-self-test",
    WIRE_LIFECYCLE_SCENARIOS: "qos-1",
    WIRE_LIFECYCLE_SCENARIO_RUNNER: runner,
    WIRE_LIFECYCLE_WALL_SECONDS: "5",
    WIRE_LIFECYCLE_NO_PROGRESS_SECONDS: "1",
    WIRE_LIFECYCLE_TERM_GRACE_SECONDS: "1",
    WIRE_LIFECYCLE_KILL_GRACE_SECONDS: "1",
    WIRE_LIFECYCLE_REAP_SECONDS: "1",
    WIRE_LIFECYCLE_PROGRESS_INTERVAL_SECONDS: "1",
  };
  const result = spawnSync("bash", [matrixScript], {
    cwd: root,
    encoding: "utf8",
    env: matrixEnvironment,
    timeout: 10000,
  });
  const elapsed = Date.now() - started;
  if (result.error?.code === "EPERM") {
    t.skip("the managed test sandbox disallows child-process execution");
    return;
  }
  const artifactDirectory = path.join(output, "qos-1");
  const verifierLog = fs.readFileSync(path.join(artifactDirectory, "verifier.log"), "utf8");
  const processGroup = fs.readFileSync(path.join(artifactDirectory, "process-group.txt"), "utf8");

  assert.equal(result.error, undefined, result.error?.stack);
  assert.notEqual(result.status, 0, `${result.stdout ?? ""}\n${result.stderr ?? ""}`);
  assert.ok(elapsed < 10000, `hostile child exceeded test bound: ${elapsed}ms`);
  assert.match(result.stdout ?? "", /phase=no-progress-timeout/);
  const termIndex = (result.stdout ?? "").indexOf("phase=timeout-term");
  const killIndex = (result.stdout ?? "").indexOf("phase=timeout-kill");
  assert.ok(termIndex >= 0 && killIndex > termIndex, "TERM must precede KILL");
  assert.match(result.stdout ?? "", /FINAL-DIAGNOSTIC/);
  assert.match(verifierLog, /FINAL-DIAGNOSTIC scenario=qos-1 pid=\d+/);
  assert.match(processGroup, /pid=\d+ pgid=\d+/);
  for (const inventory of [
    "process-inventory.before.txt",
    "process-inventory.after.txt",
    "process-inventory.final.txt",
    "container-inventory.before.txt",
    "container-inventory.after.txt",
    "container-inventory.final.txt",
  ]) {
    assert.ok(fs.statSync(path.join(artifactDirectory, inventory)).size > 0, inventory);
  }

  const processIds = processGroup.match(/pid=(\d+) pgid=(\d+)/);
  assert.ok(processIds);
  const pid = Number(processIds?.[1]);
  const pgid = Number(processIds?.[2]);
  assert.ok(Number.isInteger(pid) && pid > 1);
  assert.equal(pid, pgid);
  assert.throws(() => process.kill(pid, 0), /ESRCH/);
  const descendant = Number(fs.readFileSync(path.join(artifactDirectory, "hostile-descendant.pid"), "utf8"));
  assert.ok(Number.isInteger(descendant) && descendant > 1);
  assert.throws(() => process.kill(descendant, 0), /ESRCH/);

  const leaderExitOutput = path.join(temporary, "leader-exit-run");
  const leaderExitResult = spawnSync("bash", [matrixScript], {
    cwd: root,
    encoding: "utf8",
    env: {
      ...matrixEnvironment,
      WIRE_LIFECYCLE_RUN_DIR: leaderExitOutput,
      WIRE_LIFECYCLE_SCENARIOS: "qos-2",
      WIRE_LIFECYCLE_SCENARIO_RUNNER: leaderExitsRunner,
    },
    timeout: 10000,
  });
  assert.equal(leaderExitResult.error, undefined, leaderExitResult.error?.stack);
  assert.notEqual(leaderExitResult.status, 0, `${leaderExitResult.stdout ?? ""}\n${leaderExitResult.stderr ?? ""}`);
  assert.match(leaderExitResult.stdout ?? "", /phase=timeout-kill/);
  const leaderExitArtifact = path.join(leaderExitOutput, "qos-2");
  const leaderExitDescendant = Number(fs.readFileSync(path.join(leaderExitArtifact, "hostile-descendant.pid"), "utf8"));
  assert.ok(Number.isInteger(leaderExitDescendant) && leaderExitDescendant > 1);
  assert.throws(() => process.kill(leaderExitDescendant, 0), /ESRCH/);

  const ownershipOutput = path.join(temporary, "ownership-failure-run");
  const ownershipResult = spawnSync("bash", [matrixScript], {
    cwd: root,
    encoding: "utf8",
    env: {
      ...matrixEnvironment,
      WIRE_LIFECYCLE_RUN_DIR: ownershipOutput,
      WIRE_LIFECYCLE_TEST_FORCE_PGID: "1",
      WIRE_LIFECYCLE_SCENARIO_RUNNER: fastRunner,
    },
    timeout: 10000,
  });
  assert.equal(ownershipResult.error, undefined, ownershipResult.error?.stack);
  assert.equal(ownershipResult.status, 125, `${ownershipResult.stdout ?? ""}\n${ownershipResult.stderr ?? ""}`);
  assert.match(ownershipResult.stdout ?? "", /phase=ownership-failed/);
  assert.ok(fs.statSync(path.join(ownershipOutput, "qos-1", "process-inventory.final.txt")).size > 0);

  const runtimeCalls = fs.readFileSync(runtimeLog, "utf8");
  assert.match(runtimeCalls, /label=io\.axoloty\.managed-by=axoloty-wire-lifecycle/);
  assert.match(runtimeCalls, /label=io\.axoloty\.run-id=hostile-self-test/);
  assert.match(runtimeCalls, /label=io\.axoloty\.scenario=qos-1/);
});
