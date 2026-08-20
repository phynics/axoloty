// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const subjectScripts = [
  "Tests/WireCompatibility/IO/Live/run-io-associate-js-to-modern.sh",
  "Tests/WireCompatibility/IO/Live/run-io-associate.sh",
  "Tests/WireCompatibility/Lifecycle/Live/run-lifecycle-call-return.sh",
  "Tests/WireCompatibility/Lifecycle/Live/run-lifecycle-network.sh",
  "Tests/WireCompatibility/Reverse/run-axoloty-advertise.sh",
  "Tests/WireCompatibility/Reverse/run-axoloty-core.sh",
  "Tests/WireCompatibility/Reverse/run-coatyjs-to-axoloty-advertise.sh",
  "Tests/WireCompatibility/Reverse/run-coatyjs-to-axoloty-core.sh",
];

test("nested live-wire Swift commands isolate their module cache", () => {
  for (const relativePath of subjectScripts) {
    const source = readFileSync(path.join(root, relativePath), "utf8");
    const swiftCommands = source.match(/"\$DEV_IMAGE" swift (?:build|test)/g) ?? [];
    const isolatedCommands = source.match(/-e "SWIFTPM_MODULECACHE_OVERRIDE=\$SWIFTPM_MODULECACHE_OVERRIDE"/g) ?? [];
    const isolatedCompilerCommands = source.match(/-Xswiftc -module-cache-path -Xswiftc "\$SWIFTPM_MODULECACHE_OVERRIDE"/g) ?? [];

    assert.ok(swiftCommands.length > 0, `${relativePath} must launch Swift`);
    assert.equal(isolatedCommands.length, swiftCommands.length, relativePath);
    assert.equal(isolatedCompilerCommands.length, swiftCommands.length, relativePath);
    assert.match(source, /SWIFTPM_MODULECACHE_OVERRIDE=\/tmp\/axoloty-wire-module-cache/);
  }
});
