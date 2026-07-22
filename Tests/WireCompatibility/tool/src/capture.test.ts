import { test } from "node:test";
import assert from "node:assert/strict";
import { ByteQueue, readPacket } from "./capture.js";

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
