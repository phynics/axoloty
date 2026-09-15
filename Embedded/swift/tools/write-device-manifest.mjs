// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";

const [device, rawPath, outputPath] = process.argv.slice(2);
if (![device, rawPath, outputPath].every(Boolean)) {
  console.error("usage: write-device-manifest.mjs device raw-info output");
  process.exit(64);
}
const raw = fs.readFileSync(rawPath, "utf8");
if (!/ESP32-C6/i.test(raw)) {
  throw new Error("device query did not identify an ESP32-C6");
}
const output = {
  schemaVersion: 1,
  device,
  chip: "esp32c6",
  queried: true,
  rawInfoPath: rawPath,
};
const temporary = `${outputPath}.tmp-${process.pid}`;
fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(temporary, `${JSON.stringify(output, null, 2)}\n`, { mode: 0o644 });
fs.renameSync(temporary, outputPath);
