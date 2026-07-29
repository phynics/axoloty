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

test("captureSerial stops promptly when aborted", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-serial-abort-"));
  const device = path.join(directory, "device");
  fs.writeFileSync(device, "");
  const controller = new AbortController();
  setTimeout(() => controller.abort(), 25);
  const started = Date.now();
  await captureSerial(device, 10, () => false, controller.signal);
  assert.ok(Date.now() - started < 1000);
  fs.rmSync(directory, { recursive: true, force: true });
});

test("captureSerial rejects captures larger than the retained-byte limit", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-serial-limit-"));
  const device = path.join(directory, "device");
  fs.writeFileSync(device, "0123456789\n");
  await assert.rejects(
    captureSerial(device, 1, () => false, undefined, { maxBytes: 5 }),
    /serial capture exceeded 5 bytes/
  );
  fs.rmSync(directory, { recursive: true, force: true });
});
