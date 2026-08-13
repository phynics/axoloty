// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import fs from "node:fs";
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

test("the ax launcher builds the mounted workspace product in the mounted cache", () => {
  const launcher = fs.readFileSync(".devcontainer/ax", "utf8");
  assert.match(launcher, /swift run/);
  assert.match(launcher, /--scratch-path/);
  assert.match(launcher, /--cache-path/);
  assert.match(launcher, /\bax\b/);
});

test("published content-keyed images avoid repeated fallback builds and refresh the lock", () => {
  assert.match(setupAction, /candidate_tag=.*swift-6\.3-\$actual_hash/);
  assert.match(setupAction, /candidate_hash=.*image inspect/);
  assert.match(setupAction, /automated lock-refresh PR is pending/);
  assert.match(imageWorkflow, /pull-requests: write/);
  assert.match(imageWorkflow, /if: github\.ref == 'refs\/heads\/main'/);
  assert.match(imageWorkflow, /Open image lock refresh pull request/);
  assert.match(imageWorkflow, /contents\/\.devcontainer\/image-lock\.json/);
  assert.match(imageWorkflow, /branch="automation\/dev-image-lock"/);
  assert.match(imageWorkflow, /gh pr create/);
});
