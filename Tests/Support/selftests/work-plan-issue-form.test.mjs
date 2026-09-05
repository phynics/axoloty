// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

test("work plan issue form requires every planning section", () => {
  const contents = fs.readFileSync(path.resolve(import.meta.dirname, "../../../.github/ISSUE_TEMPLATE/work-plan.yml"), "utf8");
  for (const field of ["outcome", "in_scope", "non_goals", "dependencies", "design_decisions", "implementation_checklist", "acceptance_criteria", "validation_commands"]) {
    assert.match(contents, new RegExp(`id: ${field}`));
  }
  assert.equal(contents.match(/required: true/g)?.length, 8);
});
