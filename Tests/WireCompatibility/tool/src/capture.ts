// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { connect, type Socket } from "net";
import { openSync, writeSync, closeSync, renameSync, writeFileSync } from "fs";
import { randomUUID } from "crypto";
import { dirname, basename, resolve } from "path";

/** MQTT control packet type byte values (upper nibble of byte 0). */
const FixedHeader = {
  CONNECT: 0x10,
  CONNACK: 0x20,
  PUBLISH: 0x30,
  PUBACK: 0x40,
  SUBSCRIBE: 0x82,
  SUBACK: 0x90,
} as const;

export interface CaptureOptions {
  topicFilter: string;
  output: string;
  host: string;
  port: number;
  qos: 0 | 1;
  producer: string;
  producerVersion: string;
  scenario: string;
  normalizationProfile: string;
  count: number;
  timeout: number;
  readyFile?: string;
}

interface ParsedPublish {
  topic: string;
  payload: Buffer;
  qos: number;
  retain: boolean;
  duplicate: boolean;
  packetId: number | null;
}

/**
 * Accumulating buffer that collects 'data' events from the socket and lets
 * callers read exact byte counts asynchronously.
 */
export class ByteQueue {
  private chunks: Buffer[] = [];
  private totalBytes = 0;
  private waiters: {
    length: number;
    resolve: (value: Buffer) => void;
    reject: (reason: Error) => void;
  }[] = [];
  private ended = false;

  push(data: Buffer): void {
    this.chunks.push(data);
    this.totalBytes += data.length;
    this.notify();
  }

  signalEnd(): void {
    this.ended = true;
    this.notify();
  }

  get available(): number {
    return this.totalBytes;
  }

  get isEnded(): boolean {
    return this.ended;
  }

  /** Read exactly `length` bytes. Blocks until enough data arrives or EOF. */
  readExact(length: number): Promise<Buffer> {
    if (length === 0) {
      return Promise.resolve(Buffer.alloc(0));
    }
    if (this.totalBytes >= length) {
      return Promise.resolve(this.consume(length));
    }
    return new Promise((resolve, reject) => {
      this.waiters.push({ length, resolve, reject });
    });
  }

  private consume(length: number): Buffer {
    const result = Buffer.alloc(length);
    let offset = 0;
    while (offset < length) {
      const chunk = this.chunks[0]!;
      const remaining = length - offset;
      if (chunk.length <= remaining) {
        chunk.copy(result, offset);
        offset += chunk.length;
        this.chunks.shift();
        this.totalBytes -= chunk.length;
      } else {
        chunk.copy(result, offset, 0, remaining);
        this.chunks[0] = chunk.subarray(remaining);
        this.totalBytes -= remaining;
        offset = length;
      }
    }
    return result;
  }

  private notify(): void {
    while (this.waiters.length > 0) {
      const waiter = this.waiters[0]!;
      if (this.totalBytes >= waiter.length) {
        this.waiters.shift();
        waiter.resolve(this.consume(waiter.length));
      } else if (this.ended) {
        this.waiters.shift();
        waiter.reject(new Error("broker closed the connection"));
      } else {
        break;
      }
    }
  }
}

/** Encode an MQTT remaining-length field. */
function encodeRemainingLength(value: number): Buffer {
  const bytes: number[] = [];
  let remaining = value;
  do {
    let digit = remaining % 128;
    remaining = Math.floor(remaining / 128);
    if (remaining > 0) {
      digit |= 0x80;
    }
    bytes.push(digit);
  } while (remaining > 0);
  return Buffer.from(bytes);
}

/** Encode a UTF-8 MQTT string (2-byte length prefix + UTF-8 bytes). */
function mqttString(value: string): Buffer {
  const encoded = Buffer.from(value, "utf-8");
  return Buffer.concat([Buffer.from([(encoded.length >> 8) & 0xff, encoded.length & 0xff]), encoded]);
}

/** Build a complete MQTT packet from its type/flags byte and body. */
function buildPacket(typeAndFlags: number, body: Buffer): Buffer {
  return Buffer.concat([Buffer.from([typeAndFlags]), encodeRemainingLength(body.length), body]);
}

/**
 * Read one complete MQTT packet: the fixed header byte + remaining-length
 * field + the remaining body. Returns the first byte and the body.
 */
export async function readPacket(queue: ByteQueue, timeout: number): Promise<[number, Buffer]> {
  let timer: NodeJS.Timeout | null = null;
  const timeoutPromise = timeout > 0
    ? new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
          reject(new Error(`timed out reading MQTT packet after ${timeout}s`));
        }, timeout * 1000);
      })
    : null;

  try {
    const read = async (length: number): Promise<Buffer> => {
      const result = queue.readExact(length);
      return timeoutPromise === null ? result : Promise.race([result, timeoutPromise]);
    };
    const firstByteBuf = await read(1);
    const firstByte = firstByteBuf[0]!;

    let remaining = 0;
    let multiplier = 1;
    for (let i = 0; i < 4; i++) {
      const digitBuf = await read(1);
      const digit = digitBuf[0]!;
      remaining += (digit & 0x7f) * multiplier;
      if ((digit & 0x80) === 0) {
        break;
      }
      multiplier *= 128;
      if (i === 3) {
        throw new Error("malformed MQTT remaining length");
      }
    }

    const body = remaining > 0 ? await read(remaining) : Buffer.alloc(0);
    return [firstByte, body];
  } finally {
    if (timer) {
      clearTimeout(timer);
    }
  }
}

/** Parse a PUBLISH packet's variable header and payload. */
function parsePublish(firstByte: number, body: Buffer): ParsedPublish {
  const topicLength = (body[0]! << 8) | body[1]!;
  const topic = body.subarray(2, 2 + topicLength).toString("utf-8");
  let offset = 2 + topicLength;

  const qos = (firstByte >> 1) & 0x03;
  let packetId: number | null = null;
  if (qos > 0) {
    packetId = (body[offset]! << 8) | body[offset + 1]!;
    offset += 2;
  }

  return {
    topic,
    payload: body.subarray(offset),
    qos,
    retain: (firstByte & 0x01) !== 0,
    duplicate: (firstByte & 0x08) !== 0,
    packetId,
  };
}

/** Build a JSONL capture record from a parsed PUBLISH packet. */
function captureRecord(msg: ParsedPublish, opts: CaptureOptions, sequence: number): string {
  return JSON.stringify({
    format: "coaty-wire-capture/v1",
    producer: {
      implementation: opts.producer,
      version: opts.producerVersion,
    },
    scenario: opts.scenario,
    sequence,
    capturedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    mqtt: {
      topic: msg.topic,
      qos: msg.qos,
      retain: msg.retain,
      duplicate: msg.duplicate,
    },
    payload: {
      encoding: "base64",
      bytes: msg.payload.toString("base64"),
    },
    normalizationProfile: opts.normalizationProfile,
  }) + "\n";
}

/** Atomically create the ready file to signal subscription is active. */
function markReady(readyFile: string): void {
  const dir = dirname(readyFile);
  const tmp = resolve(dir, `.${basename(readyFile)}.${process.pid}.tmp`);
  writeFileSync(tmp, "subscribed\n");
  renameSync(tmp, readyFile);
}

/** Connect, subscribe, and capture PUBLISH packets to JSONL. */
export async function runCapture(opts: CaptureOptions): Promise<void> {
  const socket = connect({ host: opts.host, port: opts.port });
  const queue = new ByteQueue();

  socket.on("data", (data: Buffer) => {
    queue.push(data);
  });
  socket.on("close", () => {
    queue.signalEnd();
  });

  // Wait for connection.
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`connection timed out after ${opts.timeout}s`));
    }, opts.timeout * 1000);

    socket.once("connect", () => {
      clearTimeout(timer);
      resolve();
    });
    socket.once("error", (err: Error) => {
      clearTimeout(timer);
      reject(err);
    });
  });

  // CONNECT
  const clientId = "coaty-wire-capture-" + randomUUID().replace(/-/g, "").slice(0, 12);
  const connectBody = Buffer.concat([
    mqttString("MQTT"),
    Buffer.from([4, 2]), // protocol level 4 (3.1.1), connect flags: clean session
    Buffer.from([0, 0]), // keep alive = 0
    mqttString(clientId),
  ]);
  socket.write(buildPacket(FixedHeader.CONNECT, connectBody));

  // CONNACK
  const [connackType, connackBody] = await readPacket(queue, opts.timeout);
  if ((connackType >> 4) !== 2 || connackBody.length < 2 || connackBody[1] !== 0) {
    throw new Error("MQTT broker rejected connection");
  }

  // SUBSCRIBE
  const subscribeBody = Buffer.concat([
    Buffer.from([0, 1]), // packet identifier = 1
    mqttString(opts.topicFilter),
    Buffer.from([opts.qos]),
  ]);
  socket.write(buildPacket(FixedHeader.SUBSCRIBE, subscribeBody));

  // SUBACK
  const [subackType, subackBody] = await readPacket(queue, opts.timeout);
  if ((subackType >> 4) !== 9 || subackBody.length < 3 || subackBody[2] === 0x80) {
    throw new Error("MQTT broker rejected subscription");
  }

  // Signal readiness if requested.
  if (opts.readyFile) {
    markReady(opts.readyFile);
  }

  // Open output file for appending.
  const fd = openSync(opts.output, "a");

  let captured = 0;
  try {
    while (opts.count === 0 || captured < opts.count) {
      const [firstByte, body] = await readPacket(queue, 0);
      const packetType = firstByte >> 4;
      if (packetType !== 3) {
        continue; // ignore non-PUBLISH packets
      }

      const msg = parsePublish(firstByte, body);
      captured++;
      writeSync(fd, captureRecord(msg, opts, captured));

      // Acknowledge QoS 1.
      if (msg.qos === 1 && msg.packetId !== null) {
        const pubackBody = Buffer.from([(msg.packetId >> 8) & 0xff, msg.packetId & 0xff]);
        socket.write(buildPacket(FixedHeader.PUBACK, pubackBody));
      } else if (msg.qos === 2) {
        throw new Error("QoS 2 capture acknowledgement is not implemented; subscribe at QoS 1");
      }
    }
  } finally {
    closeSync(fd);
    socket.destroy();
  }
}
