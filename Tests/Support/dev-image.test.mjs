// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const dockerfile = fs.readFileSync(".devcontainer/Dockerfile", "utf8");
const inputs = fs.readFileSync(".devcontainer/image-inputs.sh", "utf8");
const makefile = fs.readFileSync("Makefile", "utf8");
const setupAction = fs.readFileSync(".github/actions/setup-container/action.yml", "utf8");
const ciWorkflow = fs.readFileSync(".github/workflows/ci.yml", "utf8");
const wireWorkflow = fs.readFileSync(".github/workflows/wire-compatibility.yml", "utf8");
const swiftPMWorkflows = [
  ciWorkflow,
  fs.readFileSync(".github/workflows/docs.yml", "utf8"),
  fs.readFileSync(".github/workflows/fuzz.yml", "utf8"),
  wireWorkflow,
];
const imageWorkflow = fs.readFileSync(".github/workflows/container-image.yml", "utf8");
const openImageLockPR = fs.readFileSync(".github/scripts/open-image-lock-pr.sh", "utf8");
const requiredCIJob = ciWorkflow.slice(ciWorkflow.indexOf("  required-checks:"), ciWorkflow.indexOf("\n  coverage:"));
const coverageCIJob = ciWorkflow.slice(ciWorkflow.indexOf("  coverage:"), ciWorkflow.indexOf("\n  prune-build-caches:"));

test("required workflows isolate PR concurrency by number and preserve push evidence", () => {
  for (const workflow of [ciWorkflow, fs.readFileSync(".github/workflows/wire-compatibility.yml", "utf8")]) {
    assert.match(
      workflow,
      /group: \$\{\{ github\.workflow \}\}-\$\{\{ github\.event\.pull_request\.number \|\| github\.ref \}\}/,
      "PR concurrency must use the PR number rather than a fork-colliding head ref",
    );
    assert.match(
      workflow,
      /cancel-in-progress: \$\{\{ github\.event_name == 'pull_request' \}\}/,
      "only superseded pull-request runs may be cancelled",
    );
  }
});

function workflowStepFrom(source, name) {
  const marker = `      - name: ${name}`;
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, `missing workflow step: ${name}`);
  const nextStep = source.indexOf("\n      - name:", start + marker.length);
  return source.slice(start, nextStep === -1 ? undefined : nextStep);
}

function workflowStep(name) {
  return workflowStepFrom(ciWorkflow, name);
}

function workflowPathList(name) {
  const match = workflowStep(name).match(/          path: \|\n((?: {12}.+\n?)+)/);
  assert.ok(match, `missing cache path list: ${name}`);
  return match[1].trim().split("\n").map((line) => line.trim());
}

function workflowRunScript(name) {
  const match = workflowStep(name).match(/        run: \|\n((?: {10}.+\n?)+)/);
  assert.ok(match, `missing run script: ${name}`);
  return match[1].trimEnd().split("\n").map((line) => line.slice(10)).join("\n");
}

function setupActionRunScript() {
  const marker = "      run: |\n";
  const start = setupAction.indexOf(marker);
  assert.notEqual(start, -1, "missing setup action run script");
  const lines = setupAction.slice(start + marker.length).split("\n");
  const body = [];
  for (const line of lines) {
    if (line.length > 0 && !line.startsWith("        ")) break;
    body.push(line.length === 0 ? "" : line.slice(8));
  }
  return body.join("\n").trimEnd();
}

function imageInputHash() {
  const result = spawnSync("bash", [".devcontainer/image-inputs.sh"], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return crypto.createHash("sha256").update(result.stdout).digest("hex");
}

function installJQFixture(tempRoot) {
  const jq = path.join(tempRoot, "jq");
  fs.writeFileSync(jq, `#!/usr/bin/env node
const fs = require("node:fs");

const args = process.argv.slice(2);
const expression = args.find((argument) => argument.startsWith("."));
const file = args.at(-1);
if (!expression || !file) process.exit(2);

const value = JSON.parse(fs.readFileSync(file, "utf8"))[expression.slice(1)];
if (value === undefined || value === null) process.exit(1);
process.stdout.write(String(value) + "\\n");
`);
  fs.chmodSync(jq, 0o755);
}

function runSetupActionScenario({ availableTag = "", publisherInProgress = "false", candidateBackoffSeconds = "0", availableAfterFirstCandidate = false, candidateTagPrefix = "swift-6.3-pr-42" } = {}) {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-setup-image-"));
  const lockFile = path.join(tempRoot, "image-lock.json");
  const runtimeLog = path.join(tempRoot, "runtime.log");
  const actualHash = imageInputHash();
  installJQFixture(tempRoot);
  const fakeRuntime = path.join(tempRoot, "fake-runtime");
  const image = "ghcr.io/test/axoloty-dev";
  fs.writeFileSync(lockFile, JSON.stringify({
    image,
    digest: "sha256:locked",
    buildInputsSha256: "stale-lock",
  }));
  fs.writeFileSync(fakeRuntime, `#!/bin/sh
set -eu
printf '%s\\n' "$*" >> "$FAKE_RUNTIME_LOG"
case "$1" in
  pull)
    case "$2" in
      "$FAKE_AVAILABLE_TAG")
        if [ "$FAKE_AVAILABLE_AFTER_FIRST" = 1 ]; then
          count_file="$FAKE_RUNTIME_LOG.candidate-count"
          count=0
          [ -f "$count_file" ] && count=$(cat "$count_file")
          count=$((count + 1))
          printf '%s\\n' "$count" > "$count_file"
          [ "$count" -ge 2 ] || exit 1
        fi
        exit 0
        ;;
      *) exit 1 ;;
    esac
    ;;
  image)
    if [ "$2" = inspect ] && [ "\${3:-}" = --format ]; then
      case "\${5:-}" in
        "$FAKE_AVAILABLE_TAG") printf '%s\\n' "$FAKE_IMAGE_HASH" ;;
        *) printf '\\n' ;;
      esac
    fi
    ;;
  tag) exit 0 ;;
  build) printf 'build\\n' >> "$FAKE_RUNTIME_LOG" ;;
esac
`);
  fs.chmodSync(fakeRuntime, 0o755);

  const script = setupActionRunScript();
  const started = performance.now();
  const result = spawnSync("bash", ["-c", script], {
    cwd: ".",
    encoding: "utf8",
    timeout: 4_000,
    env: {
      ...process.env,
      // The fallback invokes the host Make image target. Do not let a
      // development-container environment inherited by the support test turn
      // that real fallback into an intentional no-op.
      AXOLOTY_DEVCONTAINER: "0",
      PATH: `${tempRoot}${path.delimiter}${process.env.PATH ?? ""}`,
      RUNTIME: fakeRuntime,
      LOCK_FILE: lockFile,
      ALLOW_BUILD_FALLBACK: "true",
      REQUIRE_CURRENT_BUILD_INPUTS: "true",
      PUBLISHER_IN_PROGRESS: publisherInProgress,
      CANDIDATE_BACKOFF_SECONDS: candidateBackoffSeconds,
      CONTENT_TAG_PREFIX: "swift-6.3",
      CANDIDATE_TAG_PREFIX: candidateTagPrefix,
      FAKE_AVAILABLE_TAG: availableTag,
      FAKE_AVAILABLE_AFTER_FIRST: availableAfterFirstCandidate ? "1" : "0",
      FAKE_IMAGE_HASH: actualHash,
      FAKE_RUNTIME_LOG: runtimeLog,
      RUNNER_TEMP: tempRoot,
      BUILD_DIR: path.join(tempRoot, "build"),
      SPM_CACHE_DIR: path.join(tempRoot, "cache"),
      IMAGE: "axoloty-dev",
    },
  });
  const elapsedMilliseconds = performance.now() - started;
  const log = fs.existsSync(runtimeLog) ? fs.readFileSync(runtimeLog, "utf8").trim().split("\n").filter(Boolean) : [];
  fs.rmSync(tempRoot, { force: true, recursive: true });
  return { result, log, elapsedMilliseconds, actualHash };
}

test("the development image does not bake root package products or source", () => {
  assert.doesNotMatch(dockerfile, /axoloty-service-builder/);
  assert.doesNotMatch(dockerfile, /COPY (?:Package\.swift|Package\.resolved|Packages|Source|Tests|Benchmarks|Tools)\b/);
  assert.doesNotMatch(dockerfile, /--product (?:ax|axoloty-mcp)\b/);
  assert.doesNotMatch(dockerfile, /COPY --from=[^\n]+\/(?:ax|axoloty-mcp)\b/);
});

test("the image gives its non-root ESP user a writable stable home", () => {
  assert.match(dockerfile, /useradd --home-dir \/tmp --no-create-home/);
  assert.doesNotMatch(dockerfile, /useradd[^\n]*--home-dir \/home\/esp/);
  assert.match(dockerfile, /git config --system --add safe\.directory \/opt\/esp\/idf/);
  assert.match(dockerfile, /safe\.directory \/opt\/esp\/idf\/components\/openthread\/openthread/);
});

test("the image includes ESP-IDF's supported compiler cache", () => {
  assert.match(dockerfile, /ARG CCACHE_VERSION=4\.5\.1-1/);
  assert.match(dockerfile, /ENV ESP_IDF_VERSION=\$\{ESP_IDF_VERSION\}/);
  assert.match(dockerfile, /"ccache=\$\{CCACHE_VERSION\}"/);
});

test("image freshness is keyed by immutable inputs and can skip a current image", () => {
  assert.match(inputs, /paths=\(/);
  for (const mutablePath of ["Package.swift", "Package.resolved", "Packages", "Source", "Tests", "Benchmarks", "Tools"]) {
    assert.doesNotMatch(inputs, new RegExp(`\\b${mutablePath.replaceAll(".", "\\.")}\\b`));
  }
  assert.match(makefile, /image-inputs\.sh/);
  assert.match(makefile, /image inspect/);
  assert.match(makefile, /io\.axoloty\.image-inputs-sha256/);
  assert.match(makefile, /if \[ "\$\$inputs_sha256" = "\$\$image_sha256" \]/);
  assert.match(makefile, /echo "Using current development image/);
});

test("setup action falls back after two missing candidate probes", () => {
  const scenario = runSetupActionScenario();
  assert.equal(scenario.result.status, 0, scenario.result.stderr);
  const candidatePulls = scenario.log.filter((line) => line === `pull ghcr.io/test/axoloty-dev:swift-6.3-pr-42-${scenario.actualHash}`);
  assert.equal(candidatePulls.length, 2, `${scenario.result.stderr}\n${scenario.log.join("\\n")}`);
  assert.equal(scenario.log.at(-1), "build");
  assert.match(scenario.result.stderr, /candidate probes=2/);
  assert.equal(scenario.result.stderr.trim().split("\n").length, 2, scenario.result.stderr);
  assert.ok(scenario.elapsedMilliseconds < 5_000, `fallback took ${scenario.elapsedMilliseconds}ms`);
});

test("setup action prefers an available canonical content-keyed image", () => {
  const hash = imageInputHash();
  const availableTag = `ghcr.io/test/axoloty-dev:swift-6.3-${hash}`;
  const available = runSetupActionScenario({ availableTag });
  assert.equal(available.result.status, 0, available.result.stderr);
  assert.ok(available.log.includes(`pull ${availableTag}`));
  assert.ok(available.log.includes(`tag ${availableTag} axoloty-dev`));
  assert.equal(available.log.filter((line) => line.includes("swift-6.3-pr-42-")).length, 0);
  assert.doesNotMatch(available.result.stderr, /stale/);
});

test("setup action probes the canonical tag once when main has no separate candidate", () => {
  const hash = imageInputHash();
  const canonicalTag = `ghcr.io/test/axoloty-dev:swift-6.3-${hash}`;
  const available = runSetupActionScenario({ availableTag: canonicalTag, candidateTagPrefix: "swift-6.3" });
  assert.equal(available.result.status, 0, available.result.stderr);
  assert.equal(available.log.filter((line) => line === `pull ${canonicalTag}`).length, 1);
  assert.ok(available.log.includes(`tag ${canonicalTag} axoloty-dev`));

  const missing = runSetupActionScenario({ candidateTagPrefix: "swift-6.3" });
  assert.equal(missing.result.status, 0, missing.result.stderr);
  assert.equal(missing.log.filter((line) => line === `pull ${canonicalTag}`).length, 1);
  assert.equal(missing.log.at(-1), "build");
  assert.match(missing.result.stderr, /candidate probes=1/);
});

test("setup action keeps the publisher candidate retry bounded and synchronized", () => {
  const hash = imageInputHash();
  const candidateTag = `ghcr.io/test/axoloty-dev:swift-6.3-pr-42-${hash}`;
  const scenario = runSetupActionScenario({
    availableTag: candidateTag,
    publisherInProgress: "true",
    availableAfterFirstCandidate: true,
  });
  assert.equal(scenario.result.status, 0, scenario.result.stderr);
  assert.equal(scenario.log.filter((line) => line === `pull ${candidateTag}`).length, 2);
  assert.ok(scenario.log.includes(`tag ${candidateTag} axoloty-dev`));
  assert.match(scenario.result.stderr, /PR-published content-keyed/);
});

test("image is a no-op when Make runs inside the development container", () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-dev-image-"));
  const buildDir = path.join(tempRoot, "build");
  const cacheDir = path.join(tempRoot, "swiftpm-cache");
  const markerPath = path.join(tempRoot, "runtime-invoked");
  const fakeRuntime = path.join(tempRoot, "fail-fast-runtime");
  fs.writeFileSync(fakeRuntime, "#!/bin/sh\nprintf invoked > \"$FAKE_RUNTIME_MARKER\"\nexit 99\n");
  fs.chmodSync(fakeRuntime, 0o755);

  try {
    const result = spawnSync("make", ["--no-print-directory", "image"], {
      cwd: ".",
      encoding: "utf8",
      env: {
        ...process.env,
        AXOLOTY_DEVCONTAINER: "1",
        BUILD_DIR: buildDir,
        CONTAINER_RUNTIME: fakeRuntime,
        FAKE_RUNTIME_MARKER: markerPath,
        SPM_CACHE_DIR: cacheDir,
      },
    });

    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.existsSync(markerPath), false);
    assert.equal(fs.existsSync(buildDir), false);
    assert.equal(fs.existsSync(cacheDir), false);
  } finally {
    fs.rmSync(tempRoot, { force: true, recursive: true });
  }
});

test("nested container Make uses mounted build and SwiftPM cache paths", () => {
  const environment = { ...process.env };
  delete environment.AXOLOTY_DEVICE_LEASE_ROOT;
  delete environment.AXOLOTY_ESP_IDF_CCACHE_DIR;
  delete environment.BUILD_DIR;
  delete environment.SPM_CACHE_DIR;

  const result = spawnSync("make", ["--no-print-directory", "--just-print", "axoloty-tool", "AXOLOTY_TOOL_ARGS=--help"], {
    cwd: ".",
    encoding: "utf8",
    env: {
      ...environment,
      AXOLOTY_DEVCONTAINER: "1",
      BUILD_LOCK: "0",
      CONTAINER_RUNTIME: "",
    },
  });

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /BUILD_DIR="\/workspace\/.build"/);
  assert.match(result.stdout, /SPM_CACHE_DIR="\/workspace\/.swiftpm-cache"/);
  assert.match(result.stdout, /AXOLOTY_ESP_IDF_CCACHE_DIR="\/workspace\/.ccache"/);
  assert.match(result.stdout, /AXOLOTY_DEVICE_LEASE_ROOT="\/workspace\/.build\/device-leases"/);
  assert.doesNotMatch(result.stdout, /\/tmp\/coaty-swift-build/);
});

test("nested container Make preserves explicit mounted path overrides", () => {
  const environment = { ...process.env };
  delete environment.BUILD_DIR;
  delete environment.SPM_CACHE_DIR;
  delete environment.AXOLOTY_DEVICE_LEASE_ROOT;
  delete environment.AXOLOTY_ESP_IDF_CCACHE_DIR;

  const result = spawnSync("make", [
    "--no-print-directory",
    "--just-print",
    "axoloty-tool",
    "AXOLOTY_TOOL_ARGS=--help",
    "BUILD_DIR=/custom/build",
    "SPM_CACHE_DIR=/custom/swiftpm-cache",
    "AXOLOTY_ESP_IDF_CCACHE_DIR=/custom/ccache",
    "AXOLOTY_DEVICE_LEASE_ROOT=/custom/device-leases",
  ], {
    cwd: ".",
    encoding: "utf8",
    env: {
      ...environment,
      AXOLOTY_DEVCONTAINER: "1",
      BUILD_LOCK: "0",
      CONTAINER_RUNTIME: "",
    },
  });

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /BUILD_DIR="\/custom\/build"/);
  assert.match(result.stdout, /SPM_CACHE_DIR="\/custom\/swiftpm-cache"/);
  assert.match(result.stdout, /AXOLOTY_ESP_IDF_CCACHE_DIR="\/custom\/ccache"/);
  assert.match(result.stdout, /AXOLOTY_DEVICE_LEASE_ROOT="\/custom\/device-leases"/);
  assert.doesNotMatch(result.stdout, /\/workspace\/(?:\.build|\.swiftpm-cache)/);
});

test("Make exports the command-line mount suffix override to run.sh", () => {
  const environment = { ...process.env };
  delete environment.CONTAINER_MOUNT_SUFFIX;

  const result = spawnSync("make", [
    "--no-print-directory",
    "--file",
    "Makefile",
    "--eval",
    "show-mount-suffix:\n\t@printf \"%s\" \"$$CONTAINER_MOUNT_SUFFIX\"",
    "show-mount-suffix",
    "CONTAINER_MOUNT_SUFFIX=:Z",
  ], {
    cwd: ".",
    encoding: "utf8",
    env: environment,
  });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, ":Z");
  assert.match(makefile, /^export CONTAINER_MOUNT_SUFFIX$/m);
});

test("tool launchers use the isolated Tools package and scratch directory", () => {
  for (const executable of ["ax", "axoloty-tool"]) {
    const launcher = fs.readFileSync(`.devcontainer/${executable}`, "utf8");
    assert.match(launcher, /swift run/);
    assert.match(launcher, /--package-path Tools/);
    assert.match(launcher, /scratch_path=\$\{TOOLING_BUILD_DIR:-\/workspace\/\.build\/tooling\}/);
    assert.match(launcher, /--scratch-path "\$scratch_path"/);
    assert.match(launcher, /--cache-path/);
    assert.match(launcher, /module_cache_path=.*axoloty-tooling-module-cache/);
    assert.match(launcher, /-Xswiftc -module-cache-path -Xswiftc "\$module_cache_path"/);
    assert.match(launcher, new RegExp(`\\b${executable}\\b`));
  }
});

test("CI reuses stable, bounded Swift build cache namespaces", () => {
  assert.match(ciWorkflow, /SWIFT_BUILD_CACHE_PREFIX="swift-build-v3-compiler-6\.3-linux-\$\{image_identity\}-/);
  assert.match(ciWorkflow, /image_identity=\$[^ ]+.*\.buildInputsSha256.*\.devcontainer\/image-lock\.json/);
  assert.match(ciWorkflow, /SWIFT_BUILD_CACHE_KEY=\$\{SWIFT_BUILD_CACHE_PREFIX\}\$\{GITHUB_SHA\}/);
  const compilerCachePaths = [
    ".build/ci/build.db",
    ".build/ci/checkouts",
    ".build/ci/debug.yaml",
    ".build/ci/plugin-tools.yaml",
    ".build/ci/workspace-state.json",
    ".build/ci/plugins",
    ".build/ci/repositories",
    ".build/ci/x86_64-unknown-linux-gnu/debug/*.build",
    ".build/ci/x86_64-unknown-linux-gnu/debug/description.json",
    ".build/ci/x86_64-unknown-linux-gnu/debug/index/store",
    ".build/ci/x86_64-unknown-linux-gnu/debug/Modules",
    ".build/ci/x86_64-unknown-linux-gnu/debug/ModuleCache",
  ];
  assert.deepEqual(workflowPathList("Restore Swift compiler cache"), compilerCachePaths);
  assert.deepEqual(workflowPathList("Save Swift compiler cache"), compilerCachePaths);
  assert.doesNotMatch(ciWorkflow, /^ {12}\.build\/ci(?:-coverage)?$/m);
  assert.doesNotMatch(ciWorkflow, /^ {12}\.build\/ci-coverage\//m);
  assert.match(ciWorkflow, /key: \$\{\{ env\.SWIFT_BUILD_CACHE_KEY \}\}[\s\S]*restore-keys: \|\s+\$\{\{ env\.SWIFT_BUILD_CACHE_PREFIX \}\}/);
  assert.match(requiredCIJob, /make verify-ci CONTAINER_RUNTIME=podman BUILD_DIR="\.build\/ci" BUILD_LOCK=0/);
  assert.doesNotMatch(ciWorkflow, /BUILD_DIR="\.build\/\$\{GITHUB_SHA\}"/);
  assert.match(ciWorkflow, /actions: write/);
  assert.match(ciWorkflow, /gh cache list --ref refs\/heads\/main --key "swift-build-v3-compiler-6\.3-linux-"/);
  assert.match(ciWorkflow, /--sort created_at --order desc --limit 100 --json id --jq '\.\[2:\]\[\]\.id'/);
  assert.match(ciWorkflow, /gh cache list --ref refs\/heads\/main --key "swift-build-v2-coverage-6\.3-linux-"/);
  assert.match(ciWorkflow, /gh cache list --ref refs\/heads\/main --key "swift-build-coverage-6\.3-linux-"/);
  assert.match(ciWorkflow, /gh cache delete "\$cache_id"/);
});

test("SwiftPM caches are content-exact and safe to save after a failed plan", () => {
  for (const workflow of swiftPMWorkflows) {
    assert.match(workflow, /SWIFT_CACHE_KEY=swiftpm-v2-6\.3-linux-\$\{\{ hashFiles\('Package\.resolved', '\.devcontainer\/Dockerfile', '\.devcontainer\/image-lock\.json'\) \}\}/);
    assert.doesNotMatch(workflowStepFrom(workflow, "Restore SwiftPM dependency cache"), /restore-keys:/);
  }

  const healthStep = workflowStep("Validate SwiftPM dependency cache before failure-safe save");
  const dependencySaveStep = workflowStep("Save SwiftPM dependency cache");
  const compilerSaveStep = workflowStep("Save Swift compiler cache");
  assert.match(healthStep, /if: always\(\)[\s\S]*steps\.swiftpm_cache\.outcome == 'success'/);
  assert.match(healthStep, /make resolve CONTAINER_RUNTIME=podman BUILD_DIR="\.build\/ci" BUILD_LOCK=0 SPM_CACHE_DIR=\.swiftpm-cache/);
  assert.match(healthStep, /ready=true/);
  assert.match(healthStep, /ready=false/);
  assert.match(dependencySaveStep, /if: always\(\)[\s\S]*steps\.swiftpm_cache_health\.outputs\.ready == 'true'/);
  assert.match(compilerSaveStep, /if: success\(\)/);
  assert.doesNotMatch(compilerSaveStep, /if: always\(\)/);
});

test("CI pruning keeps two current caches and deletes superseded layouts", () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-cache-prune-"));
  const fakeBin = path.join(tempRoot, "bin");
  const fakeGh = path.join(fakeBin, "gh");
  const deleted = path.join(tempRoot, "deleted");
  fs.mkdirSync(fakeBin);
  fs.writeFileSync(fakeGh, `#!/bin/sh
set -eu
if [ "$1 $2" = "cache delete" ]; then
  printf '%s\\n' "$3" >> "$FAKE_DELETE_CAPTURE"
  exit 0
fi
key=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--key" ]; then
    shift
    key=$1
  fi
  shift
done
case "$key" in
  swift-build-v3-compiler-6.3-linux-) printf 'v3-oldest\\nv3-old\\n' ;;
  swift-build-v2-coverage-6.3-linux-) printf 'v2-old\\n' ;;
  swift-build-coverage-6.3-linux-) printf 'legacy-old\\n' ;;
  *) exit 2 ;;
esac
`);
  fs.chmodSync(fakeGh, 0o755);

  try {
    const result = spawnSync("bash", ["-c", workflowRunScript("Keep two adjacent-commit caches and remove legacy layouts")], {
      cwd: ".",
      encoding: "utf8",
      env: {
        ...process.env,
        FAKE_DELETE_CAPTURE: deleted,
        GH_REPO: "phynics/axoloty",
        GH_TOKEN: "test-token",
        PATH: `${fakeBin}:${process.env.PATH}`,
        RUNNER_TEMP: tempRoot,
      },
    });

    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(fs.readFileSync(deleted, "utf8").trim().split("\n"), [
      "v3-oldest",
      "v3-old",
      "v2-old",
      "legacy-old",
    ]);
  } finally {
    fs.rmSync(tempRoot, { force: true, recursive: true });
  }
});

test("published content-keyed images avoid repeated fallback builds and refresh the lock", () => {
  const publishPr = imageWorkflow.slice(imageWorkflow.indexOf("  publish-pr:"), imageWorkflow.indexOf("  publish-main:"));
  const publishMain = imageWorkflow.slice(imageWorkflow.indexOf("  publish-main:"));
  assert.match(setupAction, /content_tag=.*\$CONTENT_TAG_PREFIX-\$actual_hash/);
  assert.match(setupAction, /candidate_tag=.*\$CANDIDATE_TAG_PREFIX-\$actual_hash/);
  assert.match(setupAction, /candidate_hash=.*image inspect/);
  assert.match(setupAction, /candidate probes=\$candidate_attempts/);
  assert.match(imageWorkflow, /publish-pr:[\s\S]*packages: write/);
  assert.match(imageWorkflow, /publish-pr:[\s\S]*contents: read/);
  assert.match(imageWorkflow, /publish-main:[\s\S]*pull-requests: write/);
  assert.match(imageWorkflow, /if: github\.ref == 'refs\/heads\/main' && github\.event_name != 'pull_request'/);
  assert.match(imageWorkflow, /Open image lock refresh pull request/);
  assert.match(imageWorkflow, /contents\/\.devcontainer\/image-lock\.json/);
  assert.match(imageWorkflow, /branch="automation\/dev-image-lock"/);
  assert.match(imageWorkflow, /pull_request:/);
  assert.match(imageWorkflow, /head\.repo\.full_name == github\.repository/);
  assert.match(imageWorkflow, /Build and publish content-keyed image/);
  assert.match(imageWorkflow, /imagetools inspect "\$image_tag"/);
  assert.match(imageWorkflow, /Content-keyed development image already exists/);
  assert.match(imageWorkflow, /image_tag="\$IMAGE_BASE:swift-6\.3-pr-\$\{\{ github\.event\.pull_request\.number \}\}-\$build_inputs_hash"/);
  assert.match(
    publishPr,
    /canonical_tag="\$IMAGE_BASE:swift-6\.3-\$build_inputs_hash"[^]*imagetools inspect "\$canonical_tag"[^]*Promoting canonical development image to PR tag[^]*imagetools create --tag "\$image_tag" "\$canonical_tag"[^]*exit 0[^]*docker buildx build/,
  );
  assert.match(setupAction, /candidate_tag="\$image:\$CANDIDATE_TAG_PREFIX-\$actual_hash"/);
  assert.match(
    ciWorkflow,
    /candidate-tag-prefix: \$\{\{ github\.event_name == 'pull_request' && format\('swift-6\.3-pr-\{0\}', github\.event\.pull_request\.number\) \|\| 'swift-6\.3' \}\}/,
  );
  assert.match(
    publishMain,
    /if docker buildx imagetools inspect "\$image_tag"[^]*then[^]*Reusing content-keyed development image[^]*imagetools create --tag "\$IMAGE_BASE:swift-6\.3" "\$image_tag"[^]*elif ! grep -Fqi 'manifest unknown'[^]*&& ! grep -Fqi "\$image_tag: not found"[^]*exit 1[^]*else[^]*docker buildx build[^]*fi[^]*digest=/,
  );
  assert.match(imageWorkflow, /group: development-image-\$\{\{ github\.event_name == 'pull_request'[^\n]+\|\| 'main' \}\}/);
  assert.equal(imageWorkflow.match(/elif ! grep -Fqi 'manifest unknown'/g)?.length, 3);
  assert.equal(imageWorkflow.match(/&& ! grep -Fqi "\$image_tag: not found"/g)?.length, 2);
  assert.equal(imageWorkflow.match(/&& ! grep -Fqi "\$canonical_tag: not found"/g)?.length, 1);
  assert.match(
    imageWorkflow,
    /locked_tag=.*\.tag[\s\S]*locked_digest=.*\.digest[\s\S]*locked_hash=.*\.buildInputsSha256[\s\S]*if \[\[ "\$locked_tag" == "\$image_tag" && "\$locked_digest" == "\$digest" && "\$locked_hash" == "\$build_inputs_hash" \]\]; then\s+echo "Development image lock is already current\."\s+exit 0\s+fi[\s\S]*jq \\\s+--arg tag/,
  );
  assert.match(setupAction, /PUBLISHER_IN_PROGRESS/);
  assert.match(setupAction, /CANDIDATE_BACKOFF_SECONDS/);
  assert.match(setupAction, /default: "5"/);
  assert.doesNotMatch(ciWorkflow, /publisher-in-progress:/);
  assert.doesNotMatch(ciWorkflow, /wait-for-published-seconds: "600"/);
  assert.match(imageWorkflow, /\.github\/scripts\/open-image-lock-pr\.sh/);
  assert.match(openImageLockPR, /gh pr create/);
  assert.match(openImageLockPR, /GitHub Actions is not permitted to create or approve pull requests \(createPullRequest\)/);
  assert.match(openImageLockPR, /compare\/main\.\.\.automation\/dev-image-lock\?expand=1/);
  assert.match(openImageLockPR, /GITHUB_STEP_SUMMARY/);
});

test("required CI preserves the plan budget and uploads durable run evidence", () => {
  assert.match(requiredCIJob, /timeout-minutes: 90/);
  assert.match(requiredCIJob, /AXOLOTY_RUNS_DIR: \.testing\/runs/);
  assert.match(requiredCIJob, /CONTAINER_CREATE_TIMEOUT_SECONDS: "300"/);
  assert.match(requiredCIJob, /AXOLOTY_TOOL_CONTAINER_ENV_VARS="AXOLOTY_OUTPUT CONTAINER_CREATE_TIMEOUT_SECONDS AXOLOTY_RUNS_DIR"/);
  assert.match(requiredCIJob, /Upload verification run diagnostics[\s\S]*\.testing\/required-checks\.log[\s\S]*\.testing\/runs\/\*\*[\s\S]*if-no-files-found: warn/);
  assert.match(requiredCIJob, /Summarize verification evidence[\s\S]*manifest\.json[\s\S]*verifier\.log/);
  assert.doesNotMatch(requiredCIJob, /COVERAGE_BUILD_DIR|\.testing\/coverage|Upload coverage/);
  assert.match(requiredCIJob, /Save Swift compiler cache[\s\S]*if: success\(\)/);
});

test("live wire allows bounded container creation on busy runners", () => {
  assert.match(wireWorkflow, /CONTAINER_CREATE_TIMEOUT_SECONDS: "300"/);
  assert.match(
    wireWorkflow,
    /make test-wire-live[^\n]*AXOLOTY_TOOL_CONTAINER_ENV_VARS=CONTAINER_CREATE_TIMEOUT_SECONDS/,
  );
});

test("coverage is an explicit job with a truthful missing-report failure", () => {
  assert.match(coverageCIJob, /name: Source coverage/);
  assert.match(coverageCIJob, /timeout-minutes: 90/);
  assert.match(coverageCIJob, /make coverage-check CONTAINER_RUNTIME=podman BUILD_DIR="\.build\/coverage" COVERAGE_BUILD_DIR="\.build\/coverage"/);
  assert.match(coverageCIJob, /Require coverage report[\s\S]*Coverage did not produce \.testing\/coverage\/report\.json/);
  assert.match(coverageCIJob, /Upload coverage report[\s\S]*if-no-files-found: error/);
  assert.match(coverageCIJob, /Upload coverage diagnostics[\s\S]*if-no-files-found: warn/);
  assert.doesNotMatch(coverageCIJob, /actions\/cache\/save/);
});

test("image lock PR fallback accepts only the exact repository policy denial", () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-image-lock-pr-"));
  const fakeBin = path.join(tempRoot, "bin");
  const fakeGh = path.join(fakeBin, "gh");
  fs.mkdirSync(fakeBin);
  fs.writeFileSync(fakeGh, `#!/bin/sh
set -eu
case "$1 $2" in
  "pr list")
    if [ "\${FAKE_GH_LIST_FAILURE:-0}" = 1 ]; then
      printf 'GraphQL: list unavailable\\n' >&2
      exit 2
    fi
    printf 'false\\n'
    ;;
  "pr create") printf '%s\\n' "$FAKE_GH_CREATE_ERROR" >&2; exit 1 ;;
  *) printf 'unexpected gh invocation: %s\\n' "$*" >&2; exit 99 ;;
esac
`);
  fs.chmodSync(fakeGh, 0o755);

  const exactDenial = "pull request create failed: GraphQL: GitHub Actions is not permitted to create or approve pull requests (createPullRequest)";
  const run = (error, listFailure = false) => {
    const summary = path.join(tempRoot, `summary-${Math.random()}`);
    const result = spawnSync(".github/scripts/open-image-lock-pr.sh", [], {
      cwd: ".",
      encoding: "utf8",
      env: {
        ...process.env,
        FAKE_GH_CREATE_ERROR: error,
        FAKE_GH_LIST_FAILURE: listFailure ? "1" : "0",
        GITHUB_STEP_SUMMARY: summary,
        PATH: `${fakeBin}:${process.env.PATH}`,
        REPOSITORY: "phynics/axoloty",
        RUNNER_TEMP: tempRoot,
        RUN_URL: "https://github.com/phynics/axoloty/actions/runs/1",
      },
    });
    return { result, summary };
  };

  try {
    const allowed = run(exactDenial);
    assert.equal(allowed.result.status, 0, allowed.result.stderr);
    assert.match(allowed.result.stdout, /Image lock PR requires a maintainer/);
    assert.match(fs.readFileSync(allowed.summary, "utf8"), /compare\/main\.\.\.automation\/dev-image-lock\?expand=1/);

    const altered = run(`${exactDenial}\nsecondary failure`);
    assert.equal(altered.result.status, 1);
    assert.match(altered.result.stderr, /secondary failure/);

    const unexpected = run("GraphQL: transport unavailable");
    assert.equal(unexpected.result.status, 1);
    assert.match(unexpected.result.stderr, /transport unavailable/);

    const listFailure = run(exactDenial, true);
    assert.equal(listFailure.result.status, 1);
    assert.match(listFailure.result.stderr, /failed to inspect existing image lock pull requests/);
  } finally {
    fs.rmSync(tempRoot, { force: true, recursive: true });
  }
});
