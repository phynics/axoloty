import { test } from "node:test";
import assert from "node:assert/strict";
import { ByteQueue, readPacket } from "./capture.js";
import { buildManifest } from "./manifest.js";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

test("readPacket waits for a packet body split across TCP chunks", async () => {
  const queue = new ByteQueue();
  const packet = readPacket(queue, 1);

  queue.push(Buffer.from([0x30, 0x05, 0x00]));
  setTimeout(() => queue.push(Buffer.from([0x03, 0x61, 0x62, 0x63])), 10);

  const [firstByte, body] = await packet;

  assert.equal(firstByte, 0x30);
  assert.deepEqual(body, Buffer.from([0x00, 0x03, 0x61, 0x62, 0x63]));
});

test("readPacket rejects when the packet timeout expires", async () => {
  const queue = new ByteQueue();

  await assert.rejects(
    readPacket(queue, 0.01),
    /timed out reading MQTT packet after 0\.01s/,
  );
});

test("readPacket rejects malformed four-byte Remaining Length fields", async () => {
  const queue = new ByteQueue();
  queue.push(Buffer.from([0x30, 0xff, 0xff, 0xff, 0xff]));

  await assert.rejects(readPacket(queue, 1), /malformed MQTT remaining length/);
});

test("buildManifest indexes captures in stable filename order", () => {
  const directory = mkdtempSync(join(tmpdir(), "axoloty-wire-manifest-"));
  const record = (scenario: string) => JSON.stringify({
    format: "coaty-wire-capture/v1",
    producer: { implementation: "coatyjs", version: "2.4.0" },
    scenario,
    sequence: 1,
  }) + "\n";
  writeFileSync(join(directory, "z.jsonl"), record("z"));
  writeFileSync(join(directory, "a.jsonl"), record("a"));

  const manifest = buildManifest(directory);

  assert.deepEqual(manifest.captures.map((capture) => capture.file), ["a.jsonl", "z.jsonl"]);
  assert.equal(manifest.captures[0]?.recordCount, 1);
  assert.match(manifest.captures[0]?.sha256 ?? "", /^[0-9a-f]{64}$/);
});
