// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import assert from "node:assert/strict";
import fs from "node:fs";
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
