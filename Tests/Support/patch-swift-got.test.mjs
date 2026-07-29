// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const discardRule = "   *(.got .got.plt) /* TODO: GCC-382 */\n";
const replacement = "   /* Swift UnicodeDataTables requires .got/.got.plt. */\n";
const patcher = path.resolve("Embedded/swift/main/patch-swift-got.cmake");

function fixture(contents) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-tool-got-"));
  const script = path.join(directory, "sections.ld");
  fs.writeFileSync(script, contents);
  return script;
}

function patch(script) {
  return spawnSync("cmake", [`-DLINKER_SCRIPT=${script}`, "-P", patcher], { encoding: "utf8" });
}

test("replaces the exact pinned discard rule", () => {
  const script = fixture(`before\n${discardRule}after\n`);
  assert.equal(patch(script).status, 0);
  assert.equal(fs.readFileSync(script, "utf8"), `before\n${replacement}after\n`);
});

test("accepts an already patched script", () => {
  const script = fixture(replacement);
  assert.equal(patch(script).status, 0);
  assert.equal(fs.readFileSync(script, "utf8"), replacement);
});

for (const [name, contents] of [
  ["missing", "SECTIONS {}\n"],
  ["duplicate", discardRule + discardRule],
  ["mixed", discardRule + replacement],
]) {
  test(`fails closed for ${name} rules`, () => {
    const script = fixture(contents);
    assert.notEqual(patch(script).status, 0);
    assert.equal(fs.readFileSync(script, "utf8"), contents);
  });
}
