// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import { test } from "node:test";

import { encodeDeterministicCBOR, toHex } from "./goldenEncoder.js";

test("encodes CBOR primitives in shortest deterministic form", () => {
  assert.equal(toHex(encodeDeterministicCBOR(null)), "f6");
  assert.equal(toHex(encodeDeterministicCBOR(false)), "f4");
  assert.equal(toHex(encodeDeterministicCBOR(true)), "f5");
  assert.equal(toHex(encodeDeterministicCBOR(0)), "00");
  assert.equal(toHex(encodeDeterministicCBOR(23)), "17");
  assert.equal(toHex(encodeDeterministicCBOR(24)), "1818");
  assert.equal(toHex(encodeDeterministicCBOR(250)), "18fa");
  assert.equal(toHex(encodeDeterministicCBOR(255)), "18ff");
  assert.equal(toHex(encodeDeterministicCBOR(256)), "190100");
  assert.equal(toHex(encodeDeterministicCBOR(-1)), "20");
  assert.equal(toHex(encodeDeterministicCBOR(-24)), "37");
  assert.equal(toHex(encodeDeterministicCBOR(-25)), "3818");
  assert.equal(toHex(encodeDeterministicCBOR("")), "60");
  assert.equal(toHex(encodeDeterministicCBOR("IETF")), "6449455446");
  assert.equal(toHex(encodeDeterministicCBOR([])), "80");
  assert.equal(toHex(encodeDeterministicCBOR({})), "a0");
});

test("sorts map keys by encoded bytes, preserving array order", () => {
  assert.equal(toHex(encodeDeterministicCBOR({ b: 1, aa: 2, a: 3 })), "a361610361620162616102");
  assert.equal(
    toHex(encodeDeterministicCBOR([{ b: 1, a: 2 }, []])),
    "82a261610261620180",
  );
});

test("encodes pointer-selected strings as tag-37 UUIDs", () => {
  const uuid = "11111111-1111-4111-8111-111111111111";
  assert.equal(
    toHex(encodeDeterministicCBOR({ id: uuid }, ["/id"])),
    "a1626964d8255011111111111141118111111111111111",
  );
  assert.equal(
    toHex(encodeDeterministicCBOR({ ids: [uuid, uuid] }, ["/ids/*"])),
    "a16369647382d8255011111111111141118111111111111111d8255011111111111141118111111111111111",
  );
  assert.equal(
    toHex(encodeDeterministicCBOR({ id: uuid })),
    "a1626964782431313131313131312d313131312d343131312d383131312d313131313131313131313131",
  );
});
