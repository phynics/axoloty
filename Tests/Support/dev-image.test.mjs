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
const imageWorkflow = fs.readFileSync(".github/workflows/container-image.yml", "utf8");

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
  assert.match(result.stdout, /AXOLOTY_DEVICE_LEASE_ROOT="\/workspace\/.build\/device-leases"/);
  assert.doesNotMatch(result.stdout, /\/tmp\/coaty-swift-build/);
});

test("nested container Make preserves explicit mounted path overrides", () => {
  const environment = { ...process.env };
  delete environment.BUILD_DIR;
  delete environment.SPM_CACHE_DIR;
  delete environment.AXOLOTY_DEVICE_LEASE_ROOT;

  const result = spawnSync("make", [
    "--no-print-directory",
    "--just-print",
    "axoloty-tool",
    "AXOLOTY_TOOL_ARGS=--help",
    "BUILD_DIR=/custom/build",
    "SPM_CACHE_DIR=/custom/swiftpm-cache",
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

test("the ax launcher builds the mounted workspace product in the mounted cache", () => {
  const launcher = fs.readFileSync(".devcontainer/ax", "utf8");
  assert.match(launcher, /swift run/);
  assert.match(launcher, /--scratch-path/);
  assert.match(launcher, /--cache-path/);
  assert.match(launcher, /\bax\b/);
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
    fs.readFileSync(".github/workflows/ci.yml", "utf8"),
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
  assert.match(fs.readFileSync(".github/workflows/ci.yml", "utf8"), /wait-for-published-seconds: "600"/);
  assert.match(imageWorkflow, /gh pr create/);
});
