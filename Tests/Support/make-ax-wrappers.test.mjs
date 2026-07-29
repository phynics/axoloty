// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

function recipe(makefile, target) {
  const match = new RegExp(`^${target}:[^\\n]*\\n((?:\\t[^\\n]*\\n)+)`, "m").exec(makefile);
  assert.ok(match, `missing Make target: ${target}`);
  return match[1];
}

test("principal Make workflows are direct ax compatibility wrappers", () => {
  const makefile = fs.readFileSync("Makefile", "utf8");
  for (const target of [
    "check",
    "build",
    "test-wire",
    "embedded-swift-build",
    "check-embedded-swift-linker",
    "hardware-check",
    "hardware-require",
    "release-snapshots",
  ]) {
    assert.match(recipe(makefile, target), /\$\(MAKE\).*\bax\b/, `${target} must forward to ax`);
  }
});
