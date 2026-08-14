// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
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
const imageWorkflow = fs.readFileSync(".github/workflows/container-image.yml", "utf8");
const openImageLockPR = fs.readFileSync(".github/scripts/open-image-lock-pr.sh", "utf8");

function workflowStep(name) {
  const marker = `      - name: ${name}`;
  const start = ciWorkflow.indexOf(marker);
  assert.notEqual(start, -1, `missing workflow step: ${name}`);
  const nextStep = ciWorkflow.indexOf("\n      - name:", start + marker.length);
  return ciWorkflow.slice(start, nextStep === -1 ? undefined : nextStep);
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
    ".build/ci/x86_64-unknown-linux-gnu/debug/index",
    ".build/ci/x86_64-unknown-linux-gnu/debug/Modules",
    ".build/ci/x86_64-unknown-linux-gnu/debug/ModuleCache",
  ];
  assert.deepEqual(workflowPathList("Restore Swift compiler cache"), compilerCachePaths);
  assert.deepEqual(workflowPathList("Save Swift compiler cache"), compilerCachePaths);
  assert.doesNotMatch(ciWorkflow, /^ {12}\.build\/ci(?:-coverage)?$/m);
  assert.doesNotMatch(ciWorkflow, /^ {12}\.build\/ci-coverage\//m);
  assert.match(ciWorkflow, /key: \$\{\{ env\.SWIFT_BUILD_CACHE_KEY \}\}[\s\S]*restore-keys: \|\s+\$\{\{ env\.SWIFT_BUILD_CACHE_PREFIX \}\}/);
  assert.match(ciWorkflow, /BUILD_DIR="\.build\/ci" COVERAGE_BUILD_DIR="\.build\/ci-coverage"/);
  assert.doesNotMatch(ciWorkflow, /BUILD_DIR="\.build\/\$\{GITHUB_SHA\}"/);
  assert.match(ciWorkflow, /actions: write/);
  assert.match(ciWorkflow, /gh cache list --ref refs\/heads\/main --key "swift-build-v3-compiler-6\.3-linux-"/);
  assert.match(ciWorkflow, /--sort created_at --order desc --limit 100 --json id --jq '\.\[2:\]\[\]\.id'/);
  assert.match(ciWorkflow, /gh cache list --ref refs\/heads\/main --key "swift-build-v2-coverage-6\.3-linux-"/);
  assert.match(ciWorkflow, /gh cache list --ref refs\/heads\/main --key "swift-build-coverage-6\.3-linux-"/);
  assert.match(ciWorkflow, /gh cache delete "\$cache_id"/);
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
  assert.match(setupAction, /candidate_tag=.*\$CANDIDATE_TAG_PREFIX-\$actual_hash/);
  assert.match(setupAction, /candidate_hash=.*image inspect/);
  assert.match(setupAction, /automated lock-refresh PR is pending/);
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
  assert.match(setupAction, /WAIT_FOR_PUBLISHED_SECONDS/);
  assert.match(setupAction, /Waiting for the content-keyed development image publisher/);
  assert.match(ciWorkflow, /wait-for-published-seconds: "600"/);
  assert.match(imageWorkflow, /\.github\/scripts\/open-image-lock-pr\.sh/);
  assert.match(openImageLockPR, /gh pr create/);
  assert.match(openImageLockPR, /GitHub Actions is not permitted to create or approve pull requests \(createPullRequest\)/);
  assert.match(openImageLockPR, /compare\/main\.\.\.automation\/dev-image-lock\?expand=1/);
  assert.match(openImageLockPR, /GITHUB_STEP_SUMMARY/);
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
