// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  decodeCbor,
  decodePayload,
  detectPayloadFormat,
  encodeCbor,
  encodeJSONText,
  parseDiagnostic,
  renderDiagnostic,
  type CborValue,
} from "./cbor.js";

function fromHex(hex: string): Buffer {
  return Buffer.from(hex, "hex");
}

function diagnostic(hex: string): string {
  return renderDiagnostic(decodeCbor(fromHex(hex)));
}

test("renders RFC 8949 appendix A integers", () => {
  assert.equal(diagnostic("00"), "0");
  assert.equal(diagnostic("1817"), "23");
  assert.equal(diagnostic("1903e8"), "1000");
  assert.equal(diagnostic("1a000f4240"), "1000000");
  assert.equal(diagnostic("1b000000e8d4a51000"), "1000000000000");
  assert.equal(diagnostic("20"), "-1");
  assert.equal(diagnostic("3863"), "-100");
});

test("renders byte and text strings", () => {
  assert.equal(diagnostic("40"), "h''");
  assert.equal(diagnostic("4401020304"), "h'01020304'");
  assert.equal(diagnostic("60"), '""');
  assert.equal(diagnostic("6161"), '"a"');
  assert.equal(diagnostic("6449455446"), '"IETF"');
});

test("renders arrays and maps", () => {
  assert.equal(diagnostic("80"), "[]");
  assert.equal(diagnostic("83010203"), "[1, 2, 3]");
  assert.equal(diagnostic("a201020304"), "{1: 2, 3: 4}");
});

test("renders simple values, tags, and floats", () => {
  assert.equal(diagnostic("f4"), "false");
  assert.equal(diagnostic("f5"), "true");
  assert.equal(diagnostic("f6"), "null");
  assert.equal(diagnostic("f7"), "undefined");
  assert.equal(diagnostic("f0"), "simple(16)");
  assert.equal(diagnostic("f8ff"), "simple(255)");
  assert.equal(diagnostic("c074323031332d30332d32315432303a30343a30305a"), '0("2013-03-21T20:04:00Z")');
  assert.equal(diagnostic("d74401020304"), "23(h'01020304')");
  assert.equal(diagnostic("f90000"), "0.0");
  assert.equal(diagnostic("f93c00"), "1.0");
  assert.equal(diagnostic("fb3ff199999999999a"), "1.1");
  assert.equal(diagnostic("f97e00"), "NaN");
  assert.equal(diagnostic("f97c00"), "Infinity");
  assert.equal(diagnostic("f9fc00"), "-Infinity");
});

test("renders indefinite-length items", () => {
  assert.equal(diagnostic("5f42010243030405ff"), "(_ h'0102', h'030405')");
  assert.equal(diagnostic("9f018202039f0405ffff"), "[_ 1, [2, 3], [_ 4, 5]]");
  assert.equal(diagnostic("bf61610161629f0203ffff"), '{_ "a": 1, "b": [_ 2, 3]}');
});

test("rejects trailing bytes and truncation", () => {
  assert.throws(() => decodeCbor(fromHex("0000")));
  assert.throws(() => decodeCbor(fromHex("18")));
  assert.throws(() => decodeCbor(fromHex("ff")));
});

test("encodes floats at the shortest lossless width", () => {
  assert.deepEqual(encodeCbor({ type: "float", value: 1.5 }).toString("hex"), "fa3fc00000");
  assert.deepEqual(encodeCbor({ type: "float", value: 100000 }).toString("hex"), "fa47c35000");
  assert.deepEqual(encodeCbor({ type: "float", value: 1.1 }).toString("hex"), "fb3ff199999999999a");
  assert.deepEqual(encodeCbor({ type: "float", value: NaN }).toString("hex"), "f97e00");
});

test("encodes maps in deterministic key order", () => {
  const value = parseDiagnostic('{"b": 1, "a": 2}');
  assert.equal(encodeCbor(value).toString("hex"), "a2616102616201");
});

test("encodes JSON as deterministic CBOR", () => {
  assert.equal(encodeJSONText('{"a":1,"b":[2,3]}').toString("hex"), "a26161016162820203");
});

test("classifies payload bytes", () => {
  assert.equal(detectPayloadFormat(fromHex("7b2261223a317d")), "json");
  assert.equal(detectPayloadFormat(fromHex("a1616101")), "cbor");
  assert.equal(detectPayloadFormat(fromHex("ff")), "unknown");
  assert.equal(detectPayloadFormat(Buffer.alloc(0)), "unknown");
});

test("decodes CBOR payloads with a JSON projection", () => {
  const decoded = decodePayload(fromHex("a26161016162820203"));
  assert.equal(decoded.format, "cbor");
  assert.equal(decoded.diagnostic, '{"a": 1, "b": [2, 3]}');
  assert.deepEqual(decoded.json, { a: 1, b: [2, 3] });
});

test("projects tag 37 byte strings as UUID strings", () => {
  const decoded = decodePayload(fromHex("d8255000000000000000000000000000000001"));
  assert.equal(decoded.json, "00000000-0000-0000-0000-000000000001");
});

test("passes JSON payloads through unchanged", () => {
  const decoded = decodePayload(Buffer.from('{"a":1}', "utf8"));
  assert.equal(decoded.format, "json");
  assert.equal(decoded.diagnostic, '{"a":1}');
  assert.deepEqual(decoded.json, { a: 1 });
});

test("parses and re-renders diagnostic notation", () => {
  const source = '{_ "a": 1, "b": [_ 2, 3], "c": h\'0102\', "d": 23(h\'0304\')}';
  const value: CborValue = parseDiagnostic(source);
  assert.equal(renderDiagnostic(value), source);
});

test("parses negative integers and floats", () => {
  assert.equal(renderDiagnostic(parseDiagnostic("-1")), "-1");
  assert.equal(renderDiagnostic(parseDiagnostic("-100")), "-100");
  assert.equal(renderDiagnostic(parseDiagnostic("1.5")), "1.5");
  assert.equal(renderDiagnostic(parseDiagnostic("-Infinity")), "-Infinity");
});

test("preserves the sign of negative floats and zero", () => {
  assert.equal(renderDiagnostic(parseDiagnostic("-1.5")), "-1.5");
  assert.equal(encodeCbor(parseDiagnostic("-1.5")).toString("hex"), "fabfc00000");
  assert.equal(renderDiagnostic(parseDiagnostic("-0.0")), "-0.0");
  assert.equal(encodeCbor(parseDiagnostic("-0.0")).toString("hex"), "fa80000000");
  // `-0` canonicalizes to unsigned zero, matching the Swift parser.
  const zero = parseDiagnostic("-0");
  assert.equal(zero.type, "unsigned");
  assert.equal(encodeCbor(zero).toString("hex"), "00");
});

test("rejects malformed floats instead of synthesizing a value", () => {
  assert.throws(() => parseDiagnostic("1."));
  assert.throws(() => parseDiagnostic("1e"));
  assert.throws(() => parseDiagnostic("1e+"));
  assert.throws(() => parseDiagnostic("1e-"));
});

test("canonicalizes an empty chunked string to text", () => {
  const value = parseDiagnostic("(_)");
  assert.equal(value.type, "text");
  assert.equal(renderDiagnostic(value), "(_ )");
});

test("renders large integral doubles in a re-parseable form", () => {
  const rendered = renderDiagnostic(parseDiagnostic("1e300"));
  assert.equal(rendered, "1e+300");
  assert.equal(renderDiagnostic(parseDiagnostic(rendered)), rendered);
});

test("enforces decoder byte and container bounds", () => {
  // A declared array length above the container cap.
  assert.throws(() => decodeCbor(fromHex("9a000186a0")));
  // Input larger than the byte cap.
  assert.throws(() => decodeCbor(Buffer.alloc((1 << 20) + 1, 0x00)));
});

test("rejects malformed diagnostic notation", () => {
  assert.throws(() => parseDiagnostic("[1, 2"));
  assert.throws(() => parseDiagnostic("h'0'"));
  assert.throws(() => parseDiagnostic("{1: }"));
  assert.throws(() => parseDiagnostic("nope"));
});
