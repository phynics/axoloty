// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

function recipe(makefile, target) {
  const match = new RegExp(`^${target}:[^\\n]*\\n((?:\\t[^\\n]*\\n)+)`, "m").exec(makefile);
  assert.ok(match, `missing Make target: ${target}`);
  return match[1];
}

test("principal Make workflows are direct axoloty-tool wrappers", () => {
  const makefile = fs.readFileSync("Makefile", "utf8");
  for (const target of [
    "check",
    "build",
    "test-wire",
    "test-wire-live",
    "embedded-toolchain-doctor",
    "embedded-swift-build",
    "check-embedded-swift-linker",
    "hardware-check",
    "hardware-require",
    "release-snapshots",
  ]) {
    assert.match(recipe(makefile, target), /\$\(MAKE\).*\baxoloty-tool\b/, `${target} must forward to axoloty-tool`);
  }
});
