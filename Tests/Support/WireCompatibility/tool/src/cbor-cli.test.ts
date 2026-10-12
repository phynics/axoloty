// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const CLI_JAVASCRIPT = fileURLToPath(new URL("./index.js", import.meta.url));

function runCLI(args: string[]): Promise<{ code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [CLI_JAVASCRIPT, ...args], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (data) => { stdout += data.toString(); });
    child.stderr.on("data", (data) => { stderr += data.toString(); });
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

function captureFile(payloadBase64: string, topic: string): string {
  const directory = mkdtempSync(join(tmpdir(), "axoloty-cbor-"));
  const file = join(directory, "capture.jsonl");
  writeFileSync(file, JSON.stringify({
    format: "coaty-wire-capture/v1",
    producer: { implementation: "coatyjs", version: "2.4.0" },
    scenario: "advertise",
    sequence: 1,
    mqtt: { topic, qos: 1, retain: false, duplicate: false },
    payload: { encoding: "base64", bytes: payloadBase64 },
  }) + "\n");
  return file;
}

test("encode renders deterministic CBOR from JSON", async () => {
  const result = await runCLI(["encode", "--json", '{"a":1,"b":[2,3]}']);
  assert.equal(result.code, 0);
  assert.equal(result.stdout.trim(), "a26161016162820203");
});

test("encode accepts diagnostic notation", async () => {
  const result = await runCLI(["encode", "--diagnostic", "{1: 2, 3: 4}"]);
  assert.equal(result.code, 0);
  assert.equal(result.stdout.trim(), "a201020304");
});

test("decode renders captured CBOR payloads as diagnostic notation", async () => {
  const file = captureFile("oWFhAQ==", "axoloty/1/advertise");
  const result = await runCLI(["decode", file]);
  assert.equal(result.code, 0);
  assert.deepEqual(JSON.parse(result.stdout.trim()), {
    sequence: 1,
    topic: "axoloty/1/advertise",
    format: "cbor",
    diagnostic: '{"a": 1}',
  });
});

test("decode emits a JSON projection on request", async () => {
  const file = captureFile("oWFhAQ==", "axoloty/1/advertise");
  const result = await runCLI(["decode", file, "--format", "json"]);
  assert.equal(result.code, 0);
  assert.deepEqual(JSON.parse(result.stdout.trim()), {
    sequence: 1,
    topic: "axoloty/1/advertise",
    format: "cbor",
    json: { a: 1 },
  });
});

test("decode passes JSON captures through", async () => {
  const file = captureFile(Buffer.from('{"a":1}', "utf8").toString("base64"), "axoloty/1/advertise");
  const result = await runCLI(["decode", file]);
  assert.equal(result.code, 0);
  assert.deepEqual(JSON.parse(result.stdout.trim()), {
    sequence: 1,
    topic: "axoloty/1/advertise",
    format: "json",
    diagnostic: '{"a":1}',
  });
});

test("decode filters records by topic", async () => {
  const file = captureFile("oWFhAQ==", "axoloty/1/advertise");
  const result = await runCLI(["decode", file, "--topic", "axoloty/1/other"]);
  assert.equal(result.code, 0);
  assert.equal(result.stdout, "");
});
