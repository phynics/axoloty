// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import { captureSerial } from "../../../Tests/Support/serial-tools.mjs";

const [device, deadline, output, log] = process.argv.slice(2);
let result;
const lines = await captureSerial(device, Number(deadline), line => {
  const start = line.indexOf('{"schemaVersion":1,"evidenceKind":"g1-device-run"');
  if (start < 0) return false;
  result = JSON.parse(line.slice(start));
  return true;
});
fs.writeFileSync(log, lines.join("\n") + "\n");
if (!result) throw new Error(`G1 device result not observed within ${deadline}s`);
fs.writeFileSync(output, JSON.stringify(result, null, 2) + "\n");
