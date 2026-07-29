// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import assert from "node:assert/strict";
import { captureSerial, configureSerial } from "./serial-tools.mjs";

test("captureSerial parses regular-file fixture lines and stops on callback", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-serial-"));
  const device = path.join(directory, "device");
  fs.writeFileSync(device, "booting\nAXOLOTY_SMOKE_OK\nignored\n");
  assert.equal(configureSerial(device), false);
  const seen = [];
  const lines = await captureSerial(device, 1, line => {
    seen.push(line);
    return line === "AXOLOTY_SMOKE_OK";
  });
  assert.deepEqual(lines, ["booting", "AXOLOTY_SMOKE_OK"]);
  assert.deepEqual(seen, lines);
  fs.rmSync(directory, { recursive: true, force: true });
});
