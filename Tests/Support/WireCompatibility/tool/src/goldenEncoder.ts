// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/**
 * Deterministic CBOR encoder for the frozen golden corpus.
 *
 * The encoder follows RFC 8949 Section 4.2.1 deterministic encoding: definite
 * lengths, shortest-form heads, and map keys sorted by the bytewise
 * lexicographic order of their deterministic encodings. It intentionally does
 * not depend on Axoloty so that the corpus generator stays independent of the
 * implementation it pins.
 *
 * `uuidPointers` is a list of JSON-Pointer-style paths whose string values are
 * encoded as CBOR tag 37 (byte string of the 16 RFC 4122 bytes). A `*` path
 * segment matches any array index. Every other string is encoded as a text
 * string.
 */

/** A JSON-compatible value that the deterministic encoder accepts. */
export type CBORValue =
  | string
  | number
  | boolean
  | null
  | CBORValue[]
  | { [key: string]: CBORValue };

const textEncoder = new TextEncoder();
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * Encode `value` as deterministic CBOR.
 *
 * @param value The JSON-compatible value to encode.
 * @param uuidPointers JSON-Pointer paths whose strings become tag-37 UUIDs.
 * @returns The deterministic CBOR bytes.
 */
export function encodeDeterministicCBOR(
  value: CBORValue,
  uuidPointers: readonly string[] = [],
): Uint8Array {
  const patterns = uuidPointers.map(pointer => pointer.split("/"));
  return Uint8Array.from(encodeValue(value, "", patterns));
}

function encodeValue(value: CBORValue, pointer: string, patterns: readonly string[][]): number[] {
  if (typeof value === "string" && UUID_PATTERN.test(value) && matchesPointer(pointer, patterns)) {
    return encodeUuid(value);
  }
  if (value === null) return [0xf6];
  if (typeof value === "boolean") return [value ? 0xf5 : 0xf4];
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error(`non-finite number at ${pointer || "/"}`);
    return Number.isInteger(value) ? encodeInteger(value) : encodeFloat64(value);
  }
  if (typeof value === "string") return encodeText(value);
  if (Array.isArray(value)) {
    const out = encodeHead(4, value.length);
    value.forEach((item, index) => {
      out.push(...encodeValue(item, `${pointer}/${index}`, patterns));
    });
    return out;
  }
  const pairs = Object.keys(value).map(key => ({
    key: encodeText(key),
    value: encodeValue(value[key]!, `${pointer}/${key}`, patterns),
  }));
  pairs.sort((a, b) => compareBytes(a.key, b.key));
  const out = encodeHead(5, pairs.length);
  for (const pair of pairs) out.push(...pair.key, ...pair.value);
  return out;
}

function matchesPointer(pointer: string, patterns: readonly string[][]): boolean {
  if (patterns.length === 0) return false;
  const segments = pointer.split("/");
  return patterns.some(pattern => {
    if (pattern.length !== segments.length) return false;
    return pattern.every((segment, index) => segment === "*" || segment === segments[index]);
  });
}

function encodeInteger(value: number): number[] {
  const major = value < 0 ? 1 : 0;
  const argument = value < 0 ? -1 - value : value;
  return encodeHead(major, argument);
}

function encodeHead(major: number, argument: number): number[] {
  if (!Number.isInteger(argument) || argument < 0) {
    throw new Error(`invalid CBOR head argument ${argument}`);
  }
  const prefix = major << 5;
  if (argument < 24) return [prefix | argument];
  if (argument <= 0xff) return [prefix | 24, argument];
  if (argument <= 0xffff) return [prefix | 25, (argument >>> 8) & 0xff, argument & 0xff];
  if (argument <= 0xffffffff) {
    return [
      prefix | 26,
      (argument >>> 24) & 0xff,
      (argument >>> 16) & 0xff,
      (argument >>> 8) & 0xff,
      argument & 0xff,
    ];
  }
  const big = BigInt(argument);
  return [
    prefix | 27,
    Number((big >> 56n) & 0xffn),
    Number((big >> 48n) & 0xffn),
    Number((big >> 40n) & 0xffn),
    Number((big >> 32n) & 0xffn),
    Number((big >> 24n) & 0xffn),
    Number((big >> 16n) & 0xffn),
    Number((big >> 8n) & 0xffn),
    Number(big & 0xffn),
  ];
}

function encodeText(text: string): number[] {
  const bytes = textEncoder.encode(text);
  return [...encodeHead(3, bytes.length), ...bytes];
}

function encodeUuid(uuid: string): number[] {
  return [0xd8, 0x25, 0x50, ...uuidToBytes(uuid)];
}

function uuidToBytes(uuid: string): number[] {
  const hex = uuid.replace(/-/g, "");
  const bytes: number[] = [];
  for (let index = 0; index < hex.length; index += 2) {
    bytes.push(Number.parseInt(hex.slice(index, index + 2), 16));
  }
  return bytes;
}

function encodeFloat64(value: number): number[] {
  const buffer = new ArrayBuffer(8);
  new DataView(buffer).setFloat64(0, value, false);
  return [0xfb, ...new Uint8Array(buffer)];
}

function compareBytes(a: readonly number[], b: readonly number[]): number {
  const length = Math.min(a.length, b.length);
  for (let index = 0; index < length; index += 1) {
    const left = a[index]!;
    const right = b[index]!;
    if (left !== right) return left - right;
  }
  return a.length - b.length;
}

/** Format bytes as lowercase hex, used by tests and diagnostics. */
export function toHex(bytes: Uint8Array): string {
  return [...bytes].map(byte => byte.toString(16).padStart(2, "0")).join("");
}
