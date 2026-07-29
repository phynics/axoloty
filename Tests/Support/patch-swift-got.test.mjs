// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { discardRule, patchSwiftGOT, replacement } from "../../Embedded/swift/main/patch-swift-got.mjs";

function fixture(contents) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-tool-got-"));
  const script = path.join(directory, "sections.ld");
  fs.writeFileSync(script, contents);
  return script;
}

test("replaces the exact pinned discard rule", () => {
  const script = fixture(`before\n${discardRule}after\n`);
  patchSwiftGOT(script);
  assert.equal(fs.readFileSync(script, "utf8"), `before\n${replacement}after\n`);
});

test("accepts an already patched script", () => {
  const script = fixture(replacement);
  patchSwiftGOT(script);
  assert.equal(fs.readFileSync(script, "utf8"), replacement);
});

for (const [name, contents] of [
  ["missing", "SECTIONS {}\n"],
  ["duplicate", discardRule + discardRule],
  ["mixed", discardRule + replacement],
]) {
  test(`fails closed for ${name} rules`, () => {
    const script = fixture(contents);
    assert.throws(() => patchSwiftGOT(script));
    assert.equal(fs.readFileSync(script, "utf8"), contents);
  });
}
