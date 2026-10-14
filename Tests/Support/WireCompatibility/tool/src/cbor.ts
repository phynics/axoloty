// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/**
 * Minimal CBOR (RFC 8949) codec for the wire-compatibility tool.
 *
 * The tool renders captured `axoloty/1` payloads as diagnostic notation and
 * reads diagnostic notation back into deterministic CBOR bytes. The decoder is
 * deliberately lenient (it accepts indefinite-length items and non-minimal
 * heads) so it can read external producers; the encoder is deterministic per
 * RFC 8949 section 4.2.1 (preferred serialization): shortest-form heads,
 * bytewise-sorted map keys, and the shortest of single or double precision for
 * floats. Half-precision is read but never emitted, matching the authoritative
 * Swift `CBORWriter`.
 */

/** A decoded CBOR data item. */
export type CborValue =
  | { type: "unsigned"; value: bigint }
  | { type: "negative"; value: bigint }
  | { type: "bytes"; chunks: Buffer[]; indefinite: boolean }
  | { type: "text"; chunks: string[]; indefinite: boolean }
  | { type: "array"; value: CborValue[]; indefinite: boolean }
  | { type: "map"; value: [CborValue, CborValue][]; indefinite: boolean }
  | { type: "tag"; tag: bigint; value: CborValue }
  | { type: "simple"; value: number }
  | { type: "boolean"; value: boolean }
  | { type: "null" }
  | { type: "undefined" }
  | { type: "float"; value: number };

/** A structured CBOR decoding failure. */
export class CborError extends Error {}

// Bounds mirror the Swift `CBORDecodeLimits.profile` so a hostile or corrupt
// capture cannot exhaust memory in the tool.
const MAX_BYTES = 1 << 20;
const MAX_DEPTH = 32;
const MAX_ITEMS = 65_536;
const MAX_CONTAINER_LENGTH = 65_536;
const BREAK = 0xff;

class Reader {
  private offset = 0;
  private items = 0;

  constructor(private readonly bytes: Buffer) {}

  get remaining(): number {
    return this.bytes.length - this.offset;
  }

  countItem(): void {
    this.items += 1;
    if (this.items > MAX_ITEMS) {
      throw new CborError("CBOR item count exceeded");
    }
  }

  peekByte(): number {
    if (this.offset >= this.bytes.length) {
      throw new CborError("truncated CBOR input");
    }
    return this.bytes[this.offset]!;
  }

  readByte(): number {
    const value = this.peekByte();
    this.offset += 1;
    return value;
  }

  read(length: number): Buffer {
    if (length < 0 || this.offset + length > this.bytes.length) {
      throw new CborError("truncated CBOR input");
    }
    const slice = this.bytes.subarray(this.offset, this.offset + length);
    this.offset += length;
    return slice;
  }
}

function readArgument(reader: Reader, additional: number): bigint {
  if (additional < 24) return BigInt(additional);
  switch (additional) {
    case 24: return BigInt(reader.readByte());
    case 25: return BigInt(reader.read(2).readUInt16BE(0));
    case 26: return BigInt(reader.read(4).readUInt32BE(0));
    case 27: return reader.read(8).readBigUInt64BE(0);
    default:
      throw new CborError(`invalid additional information ${additional}`);
  }
}

function decodeHalf(raw: number): number {
  const sign = (raw & 0x8000) !== 0 ? -1 : 1;
  const exponent = (raw >> 10) & 0x1f;
  const fraction = raw & 0x03ff;
  if (exponent === 0) return sign * fraction * 2 ** -24;
  if (exponent === 0x1f) {
    if (fraction === 0) return sign * Infinity;
    return NaN;
  }
  return sign * (1 + fraction / 1024) * 2 ** (exponent - 15);
}

function decodeItem(reader: Reader, depth: number): CborValue {
  if (depth > MAX_DEPTH) {
    throw new CborError("CBOR nesting depth exceeded");
  }
  reader.countItem();
  const initial = reader.readByte();
  const major = initial >> 5;
  const additional = initial & 0x1f;

  switch (major) {
    case 0:
      return { type: "unsigned", value: readArgument(reader, additional) };
    case 1:
      return { type: "negative", value: readArgument(reader, additional) };
    case 2: {
      const { chunks, indefinite } = decodeStringChunks(reader, 2, additional, depth);
      return { type: "bytes", chunks, indefinite };
    }
    case 3: {
      const { chunks, indefinite } = decodeStringChunks(reader, 3, additional, depth);
      return { type: "text", chunks: chunks.map((chunk) => chunk.toString("utf8")), indefinite };
    }
    case 4:
      return decodeArray(reader, additional, depth);
    case 5:
      return decodeMap(reader, additional, depth);
    case 6: {
      const tag = readArgument(reader, additional);
      return { type: "tag", tag, value: decodeItem(reader, depth + 1) };
    }
    case 7:
      return decodeSimple(reader, additional);
    default:
      throw new CborError(`invalid major type ${major}`);
  }
}

function decodeStringChunks(
  reader: Reader,
  major: 2 | 3,
  additional: number,
  depth: number,
): { chunks: Buffer[]; indefinite: boolean } {
  if (additional === 31) {
    const chunks: Buffer[] = [];
    while (reader.peekByte() !== BREAK) {
      const item = decodeItem(reader, depth + 1);
      if (major === 2) {
        if (item.type !== "bytes" || item.indefinite) {
          throw new CborError("invalid chunk in indefinite byte string");
        }
        chunks.push(...item.chunks);
      } else {
        if (item.type !== "text" || item.indefinite) {
          throw new CborError("invalid chunk in indefinite text string");
        }
        chunks.push(Buffer.from(item.chunks.join(""), "utf8"));
      }
    }
    reader.readByte();
    return { chunks, indefinite: true };
  }
  const length = Number(readArgument(reader, additional));
  if (length > MAX_CONTAINER_LENGTH) {
    throw new CborError("CBOR container length exceeded");
  }
  return { chunks: [reader.read(length)], indefinite: false };
}

function decodeArray(reader: Reader, additional: number, depth: number): CborValue {
  if (additional === 31) {
    const items: CborValue[] = [];
    while (reader.peekByte() !== BREAK) {
      items.push(decodeItem(reader, depth + 1));
    }
    reader.readByte();
    return { type: "array", value: items, indefinite: true };
  }
  const length = Number(readArgument(reader, additional));
  if (length > MAX_CONTAINER_LENGTH) {
    throw new CborError("CBOR container length exceeded");
  }
  const items: CborValue[] = [];
  for (let index = 0; index < length; index++) {
    items.push(decodeItem(reader, depth + 1));
  }
  return { type: "array", value: items, indefinite: false };
}

function decodeMap(reader: Reader, additional: number, depth: number): CborValue {
  const entries: [CborValue, CborValue][] = [];
  if (additional === 31) {
    while (reader.peekByte() !== BREAK) {
      const key = decodeItem(reader, depth + 1);
      const value = decodeItem(reader, depth + 1);
      entries.push([key, value]);
    }
    reader.readByte();
    return { type: "map", value: entries, indefinite: true };
  }
  const length = Number(readArgument(reader, additional));
  if (length > MAX_CONTAINER_LENGTH) {
    throw new CborError("CBOR container length exceeded");
  }
  for (let index = 0; index < length; index++) {
    const key = decodeItem(reader, depth + 1);
    const value = decodeItem(reader, depth + 1);
    entries.push([key, value]);
  }
  return { type: "map", value: entries, indefinite: false };
}

function decodeSimple(reader: Reader, additional: number): CborValue {
  switch (additional) {
    case 20: return { type: "boolean", value: false };
    case 21: return { type: "boolean", value: true };
    case 22: return { type: "null" };
    case 23: return { type: "undefined" };
    case 24: return { type: "simple", value: reader.readByte() };
    case 25: return { type: "float", value: decodeHalf(reader.read(2).readUInt16BE(0)) };
    case 26: return { type: "float", value: reader.read(4).readFloatBE(0) };
    case 27: return { type: "float", value: reader.read(8).readDoubleBE(0) };
    case 31: throw new CborError("unexpected break");
    default:
      if (additional < 20) return { type: "simple", value: additional };
      throw new CborError(`invalid simple value ${additional}`);
  }
}

/** Decodes exactly one CBOR item from `bytes`. */
export function decodeCbor(bytes: Buffer): CborValue {
  if (bytes.length > MAX_BYTES) {
    throw new CborError("CBOR input exceeds maximum byte length");
  }
  const reader = new Reader(bytes);
  const value = decodeItem(reader, 0);
  if (reader.remaining !== 0) {
    throw new CborError("trailing bytes after CBOR item");
  }
  return value;
}

function renderBytes(chunks: Buffer[], indefinite: boolean): string {
  const quoted = chunks.map((chunk) => `h'${chunk.toString("hex")}'`);
  if (indefinite) return `(_ ${quoted.join(", ")})`;
  return quoted[0] ?? "h''";
}

function escapeText(value: string): string {
  let output = "";
  for (const character of value) {
    switch (character) {
      case '"': output += '\\"'; break;
      case "\\": output += "\\\\"; break;
      case "\n": output += "\\n"; break;
      case "\r": output += "\\r"; break;
      case "\t": output += "\\t"; break;
      case "\b": output += "\\b"; break;
      case "\f": output += "\\f"; break;
      default: {
        const code = character.codePointAt(0) ?? 0;
        output += code < 0x20 ? `\\u${code.toString(16).padStart(4, "0")}` : character;
      }
    }
  }
  return output;
}

function renderText(chunks: string[], indefinite: boolean): string {
  const quoted = chunks.map((chunk) => `"${escapeText(chunk)}"`);
  if (indefinite) return `(_ ${quoted.join(", ")})`;
  return quoted[0] ?? '""';
}

function renderFloat(value: number): string {
  if (Number.isNaN(value)) return "NaN";
  if (value === Infinity) return "Infinity";
  if (value === -Infinity) return "-Infinity";
  if (Object.is(value, -0)) return "-0.0";
  const literal = String(value);
  // Only append the integral `.0` when `String` did not switch to exponent
  // form, so the rendered token stays parseable by `parseNumber`.
  return Number.isInteger(value) && !/[eE]/.test(literal) ? `${literal}.0` : literal;
}

/** Renders a decoded value as RFC 8949 section 8 diagnostic notation. */
export function renderDiagnostic(value: CborValue): string {
  switch (value.type) {
    case "unsigned": return value.value.toString();
    case "negative": return (-1n - value.value).toString();
    case "bytes": return renderBytes(value.chunks, value.indefinite);
    case "text": return renderText(value.chunks, value.indefinite);
    case "array": {
      const items = value.value.map(renderDiagnostic).join(", ");
      return value.indefinite ? `[_ ${items}]` : `[${items}]`;
    }
    case "map": {
      const entries = value.value
        .map(([key, entry]) => `${renderDiagnostic(key)}: ${renderDiagnostic(entry)}`)
        .join(", ");
      return value.indefinite ? `{_ ${entries}}` : `{${entries}}`;
    }
    case "tag": return `${value.tag.toString()}(${renderDiagnostic(value.value)})`;
    case "simple": return `simple(${value.value})`;
    case "boolean": return value.value ? "true" : "false";
    case "null": return "null";
    case "undefined": return "undefined";
    case "float": return renderFloat(value.value);
  }
}

function encodeHead(major: number, argument: bigint): Buffer {
  if (argument < 24n) {
    return Buffer.from([(major << 5) | Number(argument)]);
  }
  if (argument <= 0xffn) {
    return Buffer.from([(major << 5) | 24, Number(argument)]);
  }
  if (argument <= 0xffffn) {
    const buffer = Buffer.alloc(3);
    buffer[0] = (major << 5) | 25;
    buffer.writeUInt16BE(Number(argument), 1);
    return buffer;
  }
  if (argument <= 0xffffffffn) {
    const buffer = Buffer.alloc(5);
    buffer[0] = (major << 5) | 26;
    buffer.writeUInt32BE(Number(argument), 1);
    return buffer;
  }
  const buffer = Buffer.alloc(9);
  buffer[0] = (major << 5) | 27;
  buffer.writeBigUInt64BE(argument, 1);
  return buffer;
}

function encodeFloat(value: number): Buffer {
  if (Number.isNaN(value)) {
    return Buffer.from([0xf9, 0x7e, 0x00]);
  }
  const single = Buffer.alloc(5);
  single[0] = 0xfa;
  single.writeFloatBE(value, 1);
  if (Object.is(single.readFloatBE(1), value)) {
    return single;
  }
  const double = Buffer.alloc(9);
  double[0] = 0xfb;
  double.writeDoubleBE(value, 1);
  return double;
}

function encodeInto(value: CborValue, output: Buffer[]): void {
  switch (value.type) {
    case "unsigned":
      output.push(encodeHead(0, value.value));
      return;
    case "negative":
      output.push(encodeHead(1, value.value));
      return;
    case "bytes": {
      const body = Buffer.concat(value.chunks);
      output.push(encodeHead(2, BigInt(body.length)), body);
      return;
    }
    case "text": {
      const body = Buffer.from(value.chunks.join(""), "utf8");
      output.push(encodeHead(3, BigInt(body.length)), body);
      return;
    }
    case "array":
      output.push(encodeHead(4, BigInt(value.value.length)));
      for (const item of value.value) encodeInto(item, output);
      return;
    case "map": {
      const entries = value.value
        .map(([key, entry]) => ({ key, entry, encodedKey: encodeCbor(key) }))
        .sort((left, right) => Buffer.compare(left.encodedKey, right.encodedKey));
      output.push(encodeHead(5, BigInt(entries.length)));
      for (const { key, entry } of entries) {
        encodeInto(key, output);
        encodeInto(entry, output);
      }
      return;
    }
    case "tag":
      output.push(encodeHead(6, value.tag));
      encodeInto(value.value, output);
      return;
    case "simple":
      output.push(value.value < 24
        ? Buffer.from([0xe0 | value.value])
        : Buffer.from([0xf8, value.value]));
      return;
    case "boolean":
      output.push(Buffer.from([value.value ? 0xf5 : 0xf4]));
      return;
    case "null":
      output.push(Buffer.from([0xf6]));
      return;
    case "undefined":
      output.push(Buffer.from([0xf7]));
      return;
    case "float":
      output.push(encodeFloat(value.value));
      return;
  }
}

/** Encodes a value as deterministic CBOR (RFC 8949 section 4.2.1). */
export function encodeCbor(value: CborValue): Buffer {
  const output: Buffer[] = [];
  encodeInto(value, output);
  return Buffer.concat(output);
}

function looksLikeJSON(bytes: Buffer): boolean {
  const text = bytes.toString("utf8");
  const first = text.replace(/^\s+/, "")[0];
  if (first === undefined) return false;
  return "{[}\"-0123456789tfn".includes(first);
}

/** Classifies payload bytes as JSON, CBOR, or unknown. */
export function detectPayloadFormat(bytes: Buffer): "json" | "cbor" | "unknown" {
  if (bytes.length === 0) return "unknown";
  if (looksLikeJSON(bytes)) {
    try {
      JSON.parse(bytes.toString("utf8"));
      return "json";
    } catch {
      // fall through to CBOR
    }
  }
  try {
    decodeCbor(bytes);
    return "cbor";
  } catch {
    return "unknown";
  }
}

function jsonToCbor(value: unknown): CborValue {
  if (value === null) return { type: "null" };
  if (typeof value === "boolean") return { type: "boolean", value };
  if (typeof value === "number") {
    if (Number.isInteger(value) && value >= 0) return { type: "unsigned", value: BigInt(value) };
    if (Number.isInteger(value) && value < 0) return { type: "negative", value: BigInt(-1 - value) };
    return { type: "float", value };
  }
  if (typeof value === "string") return { type: "text", chunks: [value], indefinite: false };
  if (Array.isArray(value)) {
    return { type: "array", value: value.map(jsonToCbor), indefinite: false };
  }
  if (typeof value === "object") {
    const entries: [CborValue, CborValue][] = Object.entries(value as Record<string, unknown>)
      .map(([key, entry]): [CborValue, CborValue] => [
        { type: "text", chunks: [key], indefinite: false },
        jsonToCbor(entry),
      ]);
    return { type: "map", value: entries, indefinite: false };
  }
  throw new CborError(`cannot encode JSON value of type ${typeof value}`);
}

function uuidString(bytes: Buffer): string {
  const hex = bytes.toString("hex").toUpperCase();
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20, 32),
  ].join("-");
}

function cborToJson(value: CborValue): unknown {
  switch (value.type) {
    case "unsigned":
      return value.value <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(value.value) : value.value.toString();
    case "negative": {
      const actual = -1n - value.value;
      return actual >= BigInt(Number.MIN_SAFE_INTEGER) ? Number(actual) : actual.toString();
    }
    case "bytes": {
      const body = Buffer.concat(value.chunks);
      return body.toString("base64");
    }
    case "text":
      return value.chunks.join("");
    case "array":
      return value.value.map(cborToJson);
    case "map": {
      const object: Record<string, unknown> = {};
      for (const [key, entry] of value.value) {
        object[jsonKey(key)] = cborToJson(entry);
      }
      return object;
    }
    case "tag": {
      if (value.tag === 37n && value.value.type === "bytes" && !value.value.indefinite) {
        const body = value.value.chunks[0] ?? Buffer.alloc(0);
        if (body.length === 16) return uuidString(body);
      }
      return cborToJson(value.value);
    }
    case "simple":
      return value.value;
    case "boolean":
      return value.value;
    case "null":
    case "undefined":
      return null;
    case "float":
      return value.value;
  }
}

function jsonKey(key: CborValue): string {
  if (key.type === "text") return key.chunks.join("");
  if (key.type === "tag" && key.tag === 37n && key.value.type === "bytes" && !key.value.indefinite) {
    const body = key.value.chunks[0] ?? Buffer.alloc(0);
    if (body.length === 16) return uuidString(body);
  }
  return renderDiagnostic(key);
}

/** The result of decoding a captured payload. */
export interface DecodedPayload {
  format: "json" | "cbor" | "unknown";
  diagnostic: string;
  json?: unknown;
}

/** Decodes payload bytes into diagnostic notation and an optional JSON view. */
export function decodePayload(bytes: Buffer): DecodedPayload {
  const format = detectPayloadFormat(bytes);
  if (format === "json") {
    const parsed: unknown = JSON.parse(bytes.toString("utf8"));
    return {
      format,
      diagnostic: bytes.toString("utf8"),
      json: parsed,
    };
  }
  if (format === "cbor") {
    const value = decodeCbor(bytes);
    return {
      format,
      diagnostic: renderDiagnostic(value),
      json: cborToJson(value),
    };
  }
  return { format, diagnostic: bytes.toString("hex") };
}

/** Encodes a JSON text document as deterministic CBOR bytes. */
export function encodeJSONText(text: string): Buffer {
  const parsed: unknown = JSON.parse(text);
  return encodeCbor(jsonToCbor(parsed));
}

// MARK: - Diagnostic notation parser

/** A structured diagnostic-notation parsing failure. */
export class DiagnosticParseError extends Error {}

class Parser {
  private index = 0;

  constructor(private readonly text: string) {}

  private get current(): string | undefined {
    return this.text[this.index];
  }

  private skipWhitespace(): void {
    while (this.current !== undefined && /\s/.test(this.current)) {
      this.index += 1;
    }
  }

  private match(literal: string): boolean {
    this.skipWhitespace();
    if (this.text.startsWith(literal, this.index)) {
      this.index += literal.length;
      return true;
    }
    return false;
  }

  private expect(literal: string): void {
    if (!this.match(literal)) {
      throw new DiagnosticParseError(`expected ${JSON.stringify(literal)} at offset ${this.index}`);
    }
  }

  private matchKeyword(keyword: string): boolean {
    this.skipWhitespace();
    if (!this.text.startsWith(keyword, this.index)) return false;
    const next = this.text[this.index + keyword.length];
    if (next !== undefined && /[A-Za-z0-9_]/.test(next)) return false;
    this.index += keyword.length;
    return true;
  }

  parse(): CborValue {
    const value = this.parseItem(0);
    this.skipWhitespace();
    if (this.index !== this.text.length) {
      throw new DiagnosticParseError(`unexpected trailing characters at offset ${this.index}`);
    }
    return value;
  }

  private parseItem(depth: number): CborValue {
    if (depth > MAX_DEPTH) throw new DiagnosticParseError("nesting too deep");
    this.skipWhitespace();
    const character = this.current;
    if (character === undefined) throw new DiagnosticParseError("unexpected end of input");
    if (character === "[") return this.parseArray(depth);
    if (character === "{") return this.parseMap(depth);
    if (character === "(") return this.parseChunked(depth);
    if (character === "h" && this.text[this.index + 1] === "'") return this.parseBytes();
    if (character === '"') return this.parseText();
    if (character === "-" || (character >= "0" && character <= "9")) {
      const number = this.parseNumber();
      if (number.kind === "tag") return this.parseTag(number.tag, depth);
      return number.value;
    }
    if (this.matchKeyword("true")) return { type: "boolean", value: true };
    if (this.matchKeyword("false")) return { type: "boolean", value: false };
    if (this.matchKeyword("null")) return { type: "null" };
    if (this.matchKeyword("undefined")) return { type: "undefined" };
    if (this.matchKeyword("NaN")) return { type: "float", value: NaN };
    if (this.matchKeyword("Infinity")) return { type: "float", value: Infinity };
    if (this.matchKeyword("simple")) return this.parseSimple();
    throw new DiagnosticParseError(`unexpected character ${JSON.stringify(character)} at offset ${this.index}`);
  }

  private parseArray(depth: number): CborValue {
    this.expect("[");
    const indefinite = this.match("_");
    const items: CborValue[] = [];
    this.skipWhitespace();
    if (this.current !== "]") {
      for (;;) {
        items.push(this.parseItem(depth + 1));
        this.skipWhitespace();
        if (!this.match(",")) break;
      }
    }
    this.expect("]");
    return { type: "array", value: items, indefinite };
  }

  private parseMap(depth: number): CborValue {
    this.expect("{");
    const indefinite = this.match("_");
    const entries: [CborValue, CborValue][] = [];
    this.skipWhitespace();
    if (this.current !== "}") {
      for (;;) {
        const key = this.parseItem(depth + 1);
        this.expect(":");
        const value = this.parseItem(depth + 1);
        entries.push([key, value]);
        this.skipWhitespace();
        if (!this.match(",")) break;
      }
    }
    this.expect("}");
    return { type: "map", value: entries, indefinite };
  }

  private parseChunked(depth: number): CborValue {
    this.expect("(");
    this.expect("_");
    const chunks: CborValue[] = [];
    this.skipWhitespace();
    if (this.current !== ")") {
      for (;;) {
        chunks.push(this.parseItem(depth + 1));
        this.skipWhitespace();
        if (!this.match(",")) break;
      }
    }
    this.expect(")");
    const byteChunks = chunks.every((chunk) => chunk.type === "bytes");
    const textChunks = chunks.every((chunk) => chunk.type === "text");
    // An empty `(_)` has no chunk to disambiguate it. Match the Swift parser,
    // which canonicalizes it to an empty indefinite text string.
    if (textChunks) {
      return {
        type: "text",
        chunks: chunks.flatMap((chunk) => (chunk.type === "text" ? chunk.chunks : [])),
        indefinite: true,
      };
    }
    if (byteChunks) {
      return {
        type: "bytes",
        chunks: chunks.flatMap((chunk) => (chunk.type === "bytes" ? chunk.chunks : [])),
        indefinite: true,
      };
    }
    throw new DiagnosticParseError("chunked string mixes byte and text chunks");
  }

  private parseBytes(): CborValue {
    this.expect("h'");
    const start = this.index;
    while (this.current !== undefined && this.current !== "'") this.index += 1;
    const hex = this.text.slice(start, this.index);
    this.expect("'");
    if (hex.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(hex)) {
      throw new DiagnosticParseError("invalid byte string");
    }
    return { type: "bytes", chunks: [Buffer.from(hex, "hex")], indefinite: false };
  }

  private parseText(): CborValue {
    this.expect('"');
    let output = "";
    for (;;) {
      const character = this.current;
      if (character === undefined) throw new DiagnosticParseError("unterminated text string");
      if (character === '"') {
        this.index += 1;
        break;
      }
      if (character === "\\") {
        this.index += 1;
        output += this.parseEscape();
        continue;
      }
      output += character;
      this.index += 1;
    }
    return { type: "text", chunks: [output], indefinite: false };
  }

  private parseEscape(): string {
    const escape = this.current;
    this.index += 1;
    switch (escape) {
      case '"': return '"';
      case "\\": return "\\";
      case "/": return "/";
      case "b": return "\b";
      case "f": return "\f";
      case "n": return "\n";
      case "r": return "\r";
      case "t": return "\t";
      case "u": {
        const hex = this.text.slice(this.index, this.index + 4);
        if (hex.length !== 4 || !/^[0-9a-fA-F]{4}$/.test(hex)) {
          throw new DiagnosticParseError("invalid unicode escape");
        }
        this.index += 4;
        return String.fromCharCode(parseInt(hex, 16));
      }
      default:
        throw new DiagnosticParseError(`invalid escape \\${escape ?? ""}`);
    }
  }

  private parseSimple(): CborValue {
    this.expect("simple");
    this.expect("(");
    const value = this.parseInteger();
    this.expect(")");
    if (value < 0n || value > 255n) throw new DiagnosticParseError("simple value out of range");
    return { type: "simple", value: Number(value) };
  }

  private parseTag(tag: bigint, depth: number): CborValue {
    this.expect("(");
    const value = this.parseItem(depth + 1);
    this.expect(")");
    return { type: "tag", tag, value };
  }

  private parseNumber(): { kind: "tag"; tag: bigint } | { kind: "value"; value: CborValue } {
    // Record `start` before consuming the sign so the signed token is used for
    // float parsing; the magnitude is derived from the unsigned digits only.
    const start = this.index;
    const negative = this.match("-");
    if (negative && this.matchKeyword("Infinity")) {
      return { kind: "value", value: { type: "float", value: -Infinity } };
    }
    const digitsStart = this.index;
    while (this.current !== undefined && /[0-9]/.test(this.current)) this.index += 1;
    const integerPart = this.text.slice(digitsStart, this.index);
    if (integerPart.length === 0) {
      throw new DiagnosticParseError(`invalid number at offset ${this.index}`);
    }
    let isFloat = false;
    if (this.current === ".") {
      isFloat = true;
      this.index += 1;
      const fractionStart = this.index;
      while (this.current !== undefined && /[0-9]/.test(this.current)) this.index += 1;
      if (this.index === fractionStart) {
        throw new DiagnosticParseError(`invalid number at offset ${start}`);
      }
    }
    if (this.current === "e" || this.current === "E") {
      isFloat = true;
      this.index += 1;
      const exponentSign = this.text[this.index];
      if (exponentSign === "+" || exponentSign === "-") this.index += 1;
      const exponentStart = this.index;
      while (this.current !== undefined && /[0-9]/.test(this.current)) this.index += 1;
      if (this.index === exponentStart) {
        throw new DiagnosticParseError(`invalid number at offset ${start}`);
      }
    }
    const literal = this.text.slice(start, this.index);
    const magnitude = BigInt(integerPart);
    const hasTag = !isFloat && !negative && this.text[this.index] === "(";
    if (hasTag) {
      return { kind: "tag", tag: magnitude };
    }
    if (isFloat) {
      const value = Number(literal);
      if (Number.isNaN(value)) {
        throw new DiagnosticParseError(`invalid number at offset ${start}`);
      }
      return { kind: "value", value: { type: "float", value } };
    }
    if (negative) {
      // `-0` canonicalizes to unsigned zero, matching the Swift parser.
      if (integerPart === "0") {
        return { kind: "value", value: { type: "unsigned", value: 0n } };
      }
      return { kind: "value", value: { type: "negative", value: magnitude - 1n } };
    }
    return { kind: "value", value: { type: "unsigned", value: magnitude } };
  }

  private parseInteger(): bigint {
    this.skipWhitespace();
    const start = this.index;
    while (this.current !== undefined && /[0-9]/.test(this.current)) this.index += 1;
    if (this.index === start) throw new DiagnosticParseError("expected an integer");
    return BigInt(this.text.slice(start, this.index));
  }
}

/** Parses RFC 8949 section 8 diagnostic notation. */
export function parseDiagnostic(text: string): CborValue {
  return new Parser(text).parse();
}
