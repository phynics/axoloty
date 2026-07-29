#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu
node --check Tests/WireCompatibility/ReferenceAgents/coatyjs/scenario-runner.js
node --check Tests/WireCompatibility/ReferenceAgents/coatyjs/embedded-interoperability-runner.js
node --input-type=module <<'JS'
import fs from "node:fs";
const source = fs.readFileSync("Tests/WireCompatibility/ReferenceAgents/coatyjs/embedded-interoperability-runner.js", "utf8");
for (const value of ["axoloty-embedded", "coaty.test.Device", "32400000-0000-4000-8000-000000000004", "qos: 0", "embedded-last-will-observer"]) {
  if (!source.includes(value)) throw new Error(`missing Phase 4 vector: ${value}`);
}
JS
echo "embedded CoatyJS harness syntax self-test: OK"
