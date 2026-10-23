// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const runScript = fs.readFileSync(".devcontainer/run.sh", "utf8");

function assertProcessTerminated(pid) {
  try {
    process.kill(pid, 0);
  } catch (error) {
    assert.match(String(error), /ESRCH/);
    return;
  }

  // A killed orphan can remain as a zombie when the pinned container has no
  // init reaper. It cannot execute or retain the runaway work this test is
  // guarding against, so distinguish that state from a live process.
  if (process.platform === "linux") {
    let stat;
    try {
      stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
    } catch (error) {
      assert.match(String(error), /ENOENT/);
      return;
    }
    const state = stat.slice(stat.lastIndexOf(")") + 2).trimStart()[0];
    assert.equal(state, "Z", `process ${pid} remains live`);
    return;
  }
  assert.fail(`process ${pid} remains live`);
}

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
  assert.match(runScript, /wait_for_process_completion "\$container_pid" "container command" "\$container_command_timeout"/);
  assert.match(runScript, /CONTAINER_COMMAND_TIMEOUT_SECONDS/);
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

test("legacy lifecycle helper bounds a TERM-ignoring child on Linux", () => {
  const helper = path.resolve("Tests/Support/WireCompatibility/Legacy/process-lifecycle.sh");
  const script = `
set -eu
. "${helper}"
LEGACY_TERM_GRACE_SECONDS=1 LEGACY_KILL_GRACE_SECONDS=1
export LEGACY_TERM_GRACE_SECONDS LEGACY_KILL_GRACE_SECONDS
sh -c 'trap "" TERM; while :; do sleep 0.1; done' &
child=$!
legacy_wait_for_exit "$child" 1 hostile-child
`;
  const result = spawnSync("sh", ["-c", script], { encoding: "utf8" });
  assert.equal(result.status, 124, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stderr, /legacy timeout: label=hostile-child/);
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
  assertProcessTerminated(descendant);

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
  assertProcessTerminated(leaderExitDescendant);

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

test("live lifecycle runner accepts repository-relative artifact paths", () => {
  const root = path.resolve(".");
  const runner = path.join(
    root,
    "Tests/Support/WireCompatibility/Lifecycle/Live/run-lifecycle-network.sh",
  );
  const testingRoot = path.join(root, ".testing");
  fs.mkdirSync(testingRoot, { recursive: true });
  const temporary = fs.mkdtempSync(path.join(testingRoot, "wire-relative-"));
  const runtime = path.join(temporary, "fake-runtime");
  const runtimeLog = path.join(temporary, "runtime.log");
  const relativeOutput = path.relative(root, path.join(temporary, "artifacts"));

  try {
    fs.writeFileSync(runtime, `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "\${FAKE_RUNTIME_LOG}"
exit 17
`);
    fs.chmodSync(runtime, 0o755);
    fs.mkdirSync(path.join(root, relativeOutput), { recursive: true });

    const result = spawnSync("bash", [runner, "offline-queueing"], {
      cwd: root,
      encoding: "utf8",
      env: {
        ...process.env,
        CONTAINER_RUNTIME: runtime,
        FAKE_RUNTIME_LOG: runtimeLog,
        WIRE_OUTPUT_DIR: relativeOutput,
        WIRE_RUN_ID: "relative-output-self-test",
      },
    });

    // The fake runtime stops after the boundary check. A status of 64 would
    // mean the relative path was rejected before any runtime call.
    assert.equal(result.status, 17, `${result.stdout ?? ""}\n${result.stderr ?? ""}`);
    assert.doesNotMatch(
      result.stderr ?? "",
      /WIRE_OUTPUT_DIR must be inside the repository/,
    );
    assert.match(fs.readFileSync(runtimeLog, "utf8"), /network create/);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
    try {
      fs.rmdirSync(testingRoot);
    } catch {
      // Keep a pre-existing test-output directory intact.
    }
  }
});

test("broker restart stops when the container runtime cannot stop the broker", () => {
  const root = path.resolve(".");
  const runner = path.join(
    root,
    "Tests/Support/WireCompatibility/Lifecycle/Live/run-lifecycle-network.sh",
  );
  const testingRoot = path.join(root, ".testing");
  fs.mkdirSync(testingRoot, { recursive: true });
  const temporary = fs.mkdtempSync(path.join(testingRoot, "wire-stop-failure-"));
  const runtime = path.join(temporary, "fake-runtime");
  const runtimeLog = path.join(temporary, "runtime.log");
  const stoppedRuntimeIds = path.join(temporary, "stopped-ids.txt");
  const output = path.join(temporary, "artifacts");
  const relativeOutput = path.relative(root, output);

  try {
    fs.mkdirSync(output, { recursive: true });
    fs.writeFileSync(stoppedRuntimeIds, "");
    fs.writeFileSync(runtime, `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "\${FAKE_RUNTIME_LOG}"
case "$1" in
  run)
    name=""
    previous=""
    for argument in "$@"; do
      if [ "$previous" = "--name" ]; then name="$argument"; fi
      previous="$argument"
      case "$argument" in
        /artifacts/*.capture-ready)
          touch "\${FAKE_RUNTIME_OUTPUT}/\${argument##*/}"
          ;;
      esac
    done
    printf 'id-%s\\n' "$name"
    ;;
  kill)
    if [ "\${2:-}" = "--signal" ]; then
      if [ "\${4:-}" = "id-axoloty-lifecycle-broker-broker-restart-broker-stop-failure-self-test" ]; then
        echo "injected broker stop failure" >&2
        exit 42
      fi
      printf '%s\\n' "$4" >> "\${FAKE_RUNTIME_STOPPED}"
    fi
    ;;
  inspect)
    if grep -qx "\${2:-}" "\${FAKE_RUNTIME_STOPPED}" 2>/dev/null; then printf 'exited\\n'; else printf 'running\\n'; fi
    ;;
  wait)
    printf '0\\n'
    ;;
  logs)
    printf '%s\\n' '{"state":"ready"}'
    ;;
esac
exit 0
`);
    fs.chmodSync(runtime, 0o755);

    const result = spawnSync("bash", [runner, "broker-restart"], {
      cwd: root,
      encoding: "utf8",
      env: {
        ...process.env,
        CONTAINER_RUNTIME: runtime,
        FAKE_RUNTIME_LOG: runtimeLog,
        FAKE_RUNTIME_STOPPED: stoppedRuntimeIds,
        FAKE_RUNTIME_OUTPUT: output,
        WIRE_OUTPUT_DIR: relativeOutput,
        WIRE_RUN_ID: "broker-stop-failure-self-test",
        WIRE_LIFECYCLE_DEADLINE_SECONDS: "1",
      },
    });

    assert.equal(result.error, undefined, result.error?.stack);
    assert.equal(result.status, 42, `${result.stdout ?? ""}\\n${result.stderr ?? ""}`);
    assert.match(result.stderr ?? "", /injected broker stop failure/);
    assert.doesNotMatch(result.stderr ?? "", /Timed out waiting for subject offline transition/);

    const runtimeCalls = fs.readFileSync(runtimeLog, "utf8");
    assert.match(runtimeCalls, /kill --signal TERM id-axoloty-lifecycle-probe-broker-restart-broker-stop-failure-self-test/);
    assert.match(runtimeCalls, /kill --signal TERM id-axoloty-lifecycle-broker-broker-restart-broker-stop-failure-self-test/);
    assert.equal(
      (runtimeCalls.match(/run -d --name axoloty-lifecycle-broker-broker-restart-broker-stop-failure-self-test/g) ?? []).length,
      1,
      "runner must not restart a broker that failed to stop",
    );
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
    try {
      fs.rmdirSync(testingRoot);
    } catch {
      // Keep a pre-existing test-output directory intact.
    }
  }
});

test("network lifecycle containers are unique per scenario in a shared run", () => {
  const runner = fs.readFileSync(
    "Tests/Support/WireCompatibility/Lifecycle/Live/run-lifecycle-network.sh",
    "utf8",
  );

  for (const container of ["BROKER", "PROBE", "PROXY", "SUBJECT"]) {
    assert.match(
      runner,
      new RegExp(`^${container}="axoloty-lifecycle-${container.toLowerCase()}-\\$SCENARIO-\\$RUN_ID"$`, "m"),
      `${container} must not reuse another scenario's container name`,
    );
  }
});

test("network lifecycle capture reports an exited probe before readiness timeout", () => {
  const root = path.resolve(".");
  const runner = path.join(
    root,
    "Tests/Support/WireCompatibility/Lifecycle/Live/run-lifecycle-network.sh",
  );
  const testingRoot = path.join(root, ".testing");
  fs.mkdirSync(testingRoot, { recursive: true });
  const temporary = fs.mkdtempSync(path.join(testingRoot, "capture-readiness-"));
  const runtime = path.join(temporary, "fake-runtime");
  const output = path.join(temporary, "artifacts");

  fs.writeFileSync(runtime, `#!/usr/bin/env bash
set -eu
command="$1"
shift
case "$command" in
  network) exit 0 ;;
  run) exit 0 ;;
  exec) exit 0 ;;
  inspect)
    printf 'exited\\n'
    ;;
  logs)
    printf 'capture failed: getaddrinfo ENOTFOUND broker\\n' >&2
    ;;
  rm) exit 0 ;;
  *) exit 0 ;;
esac
`);
  fs.chmodSync(runtime, 0o755);

  try {
    const result = spawnSync("bash", [runner, "reconnect-resubscribe"], {
      cwd: root,
      encoding: "utf8",
      env: {
        ...process.env,
        CONTAINER_RUNTIME: runtime,
        WIRE_OUTPUT_DIR: output,
        WIRE_RUN_ID: "failed-capture-self-test",
        WIRE_LIFECYCLE_DEADLINE_SECONDS: "1",
      },
      timeout: 3000,
    });

    assert.equal(result.error, undefined, result.error?.stack);
    assert.notEqual(result.status, 0, `${result.stdout ?? ""}\n${result.stderr ?? ""}`);
    assert.match(result.stderr ?? "", /capture failed: getaddrinfo ENOTFOUND broker/);
    assert.match(result.stderr ?? "", /Capture process exited .* before subscription readiness/);
    assert.doesNotMatch(result.stderr ?? "", /Timed out waiting for capture subscription/);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
    try {
      fs.rmdirSync(testingRoot);
    } catch {
      // Keep a pre-existing test-output directory intact.
    }
  }
});

test("network lifecycle cleanup removes only immutable IDs created by this run", () => {
  const root = path.resolve(".");
  const runner = path.join(root, "Tests/Support/WireCompatibility/Lifecycle/Live/run-lifecycle-network.sh");
  const testingRoot = path.join(root, ".testing");
  fs.mkdirSync(testingRoot, { recursive: true });
  const temporary = fs.mkdtempSync(path.join(testingRoot, "cleanup-ownership-"));
  const runtime = path.join(temporary, "fake-runtime.py");

  fs.writeFileSync(runtime, `#!/usr/bin/env python3
import json
import os
import sys

state_path = os.environ["FAKE_RUNTIME_STATE"]
with open(state_path, encoding="utf-8") as source:
    state = json.load(source)
args = sys.argv[1:]
state["calls"].append(args)
status = 0
output = ""
if args[:2] == ["network", "create"]:
    name = args[2]
    if name in state["foreign_network_names"]:
        status, output = 125, "network name already exists\\n"
    else:
        identifier = "network-owned-" + str(len(state["owned_networks"]) + 1)
        state["owned_networks"][identifier] = name
        output = identifier + "\\n"
elif args[:2] == ["network", "rm"]:
    identifier = args[2]
    if identifier not in state["owned_networks"]:
        status = 125
    else:
        del state["owned_networks"][identifier]
elif args[0] == "run" and "--name" in args:
    name = args[args.index("--name") + 1]
    if name in state["foreign_container_names"]:
        status, output = 125, "container name already exists\\n"
    else:
        identifier = "container-owned-" + str(len(state["owned_containers"]) + 1)
        state["owned_containers"][identifier] = {"name": name, "status": "running"}
        output = identifier + "\\n"
elif args[0] == "inspect":
    identifier = args[1]
    if identifier not in state["owned_containers"]:
        status = 125
    else:
        output = state["owned_containers"][identifier]["status"] + "\\n"
elif args[0] == "exec":
    identifier = args[1]
    if identifier not in state["owned_containers"]:
        status = 125
    else:
        # The broker drops to another UID; an exec process may lack CAP_KILL.
        status = 1
elif args[:2] == ["kill", "--signal"]:
    identifier = args[3]
    if identifier not in state["owned_containers"]:
        status = 125
    elif args[2] == "TERM":
        name = state["owned_containers"][identifier]["name"]
        if name not in state.get("term_ignored_names", []):
            state["owned_containers"][identifier]["status"] = "exited"
    else:
        state["owned_containers"][identifier]["status"] = "exited"
elif args[0] == "wait":
    if args[1] not in state["owned_containers"]:
        status = 125
elif args[0] == "logs":
    if args[1] not in state["owned_containers"]:
        status = 125
elif args[0] == "rm":
    identifier = args[-1]
    if identifier not in state["owned_containers"] or state["owned_containers"][identifier]["status"] == "running":
        status = 125
    else:
        del state["owned_containers"][identifier]

with open(state_path, "w", encoding="utf-8") as destination:
    json.dump(state, destination)
if output:
    sys.stdout.write(output)
elif status:
    sys.stderr.write("fake runtime operation failed\\n")
sys.exit(status)
`);
  fs.chmodSync(runtime, 0o755);

  const initialState = {
    foreign_network_names: [],
    foreign_container_names: [],
    term_ignored_names: [],
    owned_networks: {},
    owned_containers: {},
    calls: [],
  };
  function invoke(name, state) {
    const caseDirectory = path.join(temporary, name);
    const outputDirectory = path.join(caseDirectory, "output");
    fs.mkdirSync(outputDirectory, { recursive: true });
    const statePath = path.join(caseDirectory, "state.json");
    fs.writeFileSync(statePath, JSON.stringify(state));
    const result = spawnSync("bash", [runner, "offline-queueing"], {
      cwd: root,
      encoding: "utf8",
      timeout: 10000,
      env: {
        ...process.env,
        CONTAINER_RUNTIME: runtime,
        FAKE_RUNTIME_STATE: statePath,
        WIRE_OUTPUT_DIR: path.relative(root, outputDirectory),
        WIRE_RUN_ID: `ownership-${name}`,
        WIRE_LIFECYCLE_DEADLINE_SECONDS: "0",
      },
    });
    return { result, state: JSON.parse(fs.readFileSync(statePath, "utf8")) };
  }

  try {
    const networkName = "axoloty-lifecycle-offline-queueing-ownership-network-collision";
    const networkCollision = invoke("network-collision", {
      ...initialState,
      foreign_network_names: [networkName],
    });
    assert.equal(networkCollision.result.status, 125);
    assert.deepEqual(networkCollision.state.foreign_network_names, [networkName]);
    assert.deepEqual(networkCollision.state.owned_networks, {});
    assert.deepEqual(networkCollision.state.owned_containers, {});
    assert.equal(networkCollision.state.calls.some((call) => call[0] === "rm" || (call[0] === "network" && call[1] === "rm")), false);

    const containerName = "axoloty-lifecycle-broker-offline-queueing-ownership-container-collision";
    const containerCollision = invoke("container-collision", {
      ...initialState,
      foreign_container_names: [containerName],
    });
    assert.equal(containerCollision.result.status, 125);
    assert.deepEqual(containerCollision.state.foreign_container_names, [containerName]);
    assert.deepEqual(containerCollision.state.owned_networks, {});
    assert.deepEqual(containerCollision.state.owned_containers, {});
    assert.ok(containerCollision.state.calls.some((call) => call[0] === "network" && call[1] === "rm" && call[2] === "network-owned-1"));
    assert.equal(containerCollision.state.calls.some((call) => call[0] === "rm"), false);

    const ownedCleanup = invoke("owned-cleanup", {
      ...initialState,
      term_ignored_names: ["axoloty-lifecycle-broker-offline-queueing-ownership-owned-cleanup"],
    });
    assert.notEqual(ownedCleanup.result.status, 0);
    assert.match(ownedCleanup.result.stderr, /Timed out waiting for Mosquitto broker readiness/);
    assert.deepEqual(ownedCleanup.state.owned_networks, {});
    assert.deepEqual(ownedCleanup.state.owned_containers, {});
    assert.ok(ownedCleanup.state.calls.some((call) => call[0] === "kill" && call[1] === "--signal" && call[2] === "TERM" && call[3] === "container-owned-1"));
    assert.equal(ownedCleanup.state.calls.some((call) => call[0] === "exec" && call[2] === "kill"), false);
    assert.ok(ownedCleanup.state.calls.some((call) => call[0] === "kill" && call[1] === "--signal" && call[2] === "KILL" && call[3] === "container-owned-1"));
    assert.ok(ownedCleanup.state.calls.some((call) => call[0] === "rm" && call[1] === "container-owned-1"));
    assert.ok(ownedCleanup.state.calls.some((call) => call[0] === "network" && call[1] === "rm" && call[2] === "network-owned-1"));
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
    try {
      fs.rmdirSync(testingRoot);
    } catch {
      // Keep a pre-existing test-output directory intact.
    }
  }
});
