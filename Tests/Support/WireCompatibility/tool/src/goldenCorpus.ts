// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/**
 * Canonical golden corpus for the `coaty/3` JSON and `axoloty/1` CBOR wire
 * profiles.
 *
 * Each case carries a canonical typed Coaty Core Profile 3 payload. The
 * generator writes the payload once as compact JSON (`coaty/3`) and once as
 * deterministic CBOR (`axoloty/1`). The Swift verifier decodes and re-encodes
 * each golden within its own profile and requires byte identity. The Node
 * verifier decodes every `.cbor` golden with the independent `cbor-x` decoder
 * and requires a deep match against the paired `.json` golden.
 *
 * The corpus is frozen: regenerating it is a dedicated, reviewed change, per
 * `docs/testing.md`.
 */

import fs from "node:fs";
import path from "node:path";

import { encodeDeterministicCBOR, type CBORValue } from "./goldenEncoder.js";

const SOURCE_ID = "11111111-1111-4111-8111-111111111111";
const ACTOR_ID = "22222222-2222-4222-8222-222222222222";
const SOURCE_ID_2 = "33333333-3333-4333-8333-333333333333";
const OBJECT_ID = "55555555-5555-4555-8555-555555555555";

const ASSOCIATE_POINTERS = ["/ioSourceId", "/ioActorId"];
const DEADVERTISE_POINTERS = ["/objectIds/*"];

interface GoldenCase {
  id: string;
  family: string;
  variant: "empty" | "minimal" | "full" | "special";
  uuidPointers: readonly string[];
  value: CBORValue;
  /**
   * The compact `coaty/3` JSON to write when it differs from
   * `JSON.stringify(value)`. A CBOR-only value such as a byte string has no
   * JSON form, so its JSON golden is a documented hex-string surrogate that
   * the independent verifier's normalization also produces.
   */
  json?: string;
  /** Marks a `json` surrogate so the manifest records the deliberate mapping. */
  jsonSurrogate?: boolean;
}

/**
 * Every event family and every DTO field-presence variant. Cases are listed in
 * canonical encoder field order so that `JSON.stringify` reproduces the
 * `coaty/3` bytes.
 */
export const GOLDEN_CASES: readonly GoldenCase[] = [
  {
    id: "associate-minimal",
    family: "associate",
    variant: "minimal",
    uuidPointers: ASSOCIATE_POINTERS,
    value: { ioSourceId: SOURCE_ID, ioActorId: ACTOR_ID },
  },
  {
    id: "associate-full",
    family: "associate",
    variant: "full",
    uuidPointers: ASSOCIATE_POINTERS,
    value: {
      ioSourceId: SOURCE_ID,
      ioActorId: ACTOR_ID,
      associatingRoute: `coaty/3/fixtures/IOV/${SOURCE_ID}`,
      isExternalRoute: true,
      updateRate: 250,
    },
  },
  {
    id: "associate-rate-zero",
    family: "associate",
    variant: "special",
    uuidPointers: ASSOCIATE_POINTERS,
    value: { ioSourceId: SOURCE_ID, ioActorId: ACTOR_ID, updateRate: 0 },
  },
  {
    id: "advertise-minimal",
    family: "advertise",
    variant: "minimal",
    uuidPointers: [],
    value: { object: { objectType: "example.Thing" } },
  },
  {
    id: "advertise-full",
    family: "advertise",
    variant: "full",
    uuidPointers: [],
    value: {
      object: { objectType: "example.Thing", name: "Thing" },
      privateData: { enabled: true },
    },
  },
  {
    id: "advertise-object-uuid",
    family: "advertise",
    variant: "special",
    uuidPointers: ["/object/objectId"],
    value: { object: { objectId: OBJECT_ID, objectType: "example.Thing" } },
  },
  {
    id: "deadvertise-single",
    family: "deadvertise",
    variant: "minimal",
    uuidPointers: DEADVERTISE_POINTERS,
    value: { objectIds: [SOURCE_ID] },
  },
  {
    id: "deadvertise-multiple",
    family: "deadvertise",
    variant: "full",
    uuidPointers: DEADVERTISE_POINTERS,
    value: { objectIds: [SOURCE_ID, ACTOR_ID, OBJECT_ID] },
  },
  {
    id: "channel-empty",
    family: "channel",
    variant: "empty",
    uuidPointers: [],
    value: {},
  },
  {
    id: "channel-minimal",
    family: "channel",
    variant: "minimal",
    uuidPointers: [],
    value: { object: { objectType: "example.Thing" } },
  },
  {
    id: "channel-full",
    family: "channel",
    variant: "full",
    uuidPointers: [],
    value: {
      object: { objectType: "example.Thing" },
      objects: [{ objectType: "example.Other" }],
      privateData: { enabled: true },
    },
  },
  {
    id: "iovalue-array",
    family: "ioValue",
    variant: "minimal",
    uuidPointers: [],
    value: { payload: [0, 1, 2, 255] },
  },
  {
    id: "iovalue-object",
    family: "ioValue",
    variant: "full",
    uuidPointers: [],
    value: { payload: { temperature: 21, unit: "C" } },
  },
  {
    id: "iovalue-float-single",
    family: "ioValue",
    variant: "special",
    uuidPointers: [],
    value: { payload: 1.5 },
  },
  {
    id: "iovalue-float-double",
    family: "ioValue",
    variant: "special",
    uuidPointers: [],
    value: { payload: 1.1 },
  },
  {
    id: "iovalue-integer-wide",
    family: "ioValue",
    variant: "special",
    uuidPointers: [],
    value: { payload: 9007199254740992 },
  },
  {
    id: "iovalue-negative",
    family: "ioValue",
    variant: "special",
    uuidPointers: [],
    value: { payload: -42 },
  },
  {
    id: "iovalue-null",
    family: "ioValue",
    variant: "special",
    uuidPointers: [],
    value: { payload: null },
  },
  {
    id: "iovalue-bytes",
    family: "ioValue",
    variant: "special",
    uuidPointers: [],
    value: { payload: Uint8Array.from([0xde, 0xad, 0xbe, 0xef]) },
    json: '{"payload":"deadbeef"}',
    jsonSurrogate: true,
  },
  {
    id: "discover-empty",
    family: "discover",
    variant: "empty",
    uuidPointers: [],
    value: {},
  },
  {
    id: "discover-full",
    family: "discover",
    variant: "full",
    uuidPointers: [],
    value: {
      externalId: "external-1",
      objectId: OBJECT_ID,
      objectTypes: ["coaty.Sensor"],
      coreTypes: ["IoSource"],
    },
  },
  {
    id: "resolve-minimal",
    family: "resolve",
    variant: "minimal",
    uuidPointers: [],
    value: { object: { objectType: "example.Thing" } },
  },
  {
    id: "resolve-full",
    family: "resolve",
    variant: "full",
    uuidPointers: [],
    value: {
      object: { objectType: "example.Thing" },
      relatedObjects: [{ objectType: "example.Other" }],
      privateData: { enabled: true },
    },
  },
  {
    id: "query-empty",
    family: "query",
    variant: "empty",
    uuidPointers: [],
    value: {},
  },
  {
    id: "query-full",
    family: "query",
    variant: "full",
    uuidPointers: [],
    value: {
      objectTypes: ["coaty.Sensor"],
      coreTypes: ["IoSource"],
      objectFilter: { a: 1 },
      objectJoinConditions: [{ property: "x" }],
    },
  },
  {
    id: "retrieve-minimal",
    family: "retrieve",
    variant: "minimal",
    uuidPointers: [],
    value: { objects: [{ objectType: "example.Thing" }] },
  },
  {
    id: "retrieve-full",
    family: "retrieve",
    variant: "full",
    uuidPointers: [],
    value: {
      objects: [{ objectType: "example.Thing" }],
      privateData: { enabled: true },
    },
  },
  {
    id: "update-full",
    family: "update",
    variant: "full",
    uuidPointers: [],
    value: { object: { objectType: "example.Thing" } },
  },
  {
    id: "complete-empty",
    family: "complete",
    variant: "empty",
    uuidPointers: [],
    value: {},
  },
  {
    id: "complete-full",
    family: "complete",
    variant: "full",
    uuidPointers: [],
    value: {
      object: { objectType: "example.Thing" },
      privateData: { enabled: true },
    },
  },
  {
    id: "call-empty",
    family: "call",
    variant: "empty",
    uuidPointers: [],
    value: {},
  },
  {
    id: "call-full",
    family: "call",
    variant: "full",
    uuidPointers: [],
    value: { parameters: { op: 1 }, filter: ["f"] },
  },
  {
    id: "return-empty",
    family: "return",
    variant: "empty",
    uuidPointers: [],
    value: {},
  },
  {
    id: "return-full",
    family: "return",
    variant: "full",
    uuidPointers: [],
    value: {
      result: { ok: true },
      executionInfo: { ms: 1 },
      error: { code: 2 },
    },
  },
  {
    id: "iostate-minimal",
    family: "ioState",
    variant: "minimal",
    uuidPointers: [],
    value: { hasAssociations: false },
  },
  {
    id: "iostate-rate",
    family: "ioState",
    variant: "full",
    uuidPointers: [],
    value: { hasAssociations: true, updateRate: 250 },
  },
  {
    id: "iostate-rate-zero",
    family: "ioState",
    variant: "special",
    uuidPointers: [],
    value: { hasAssociations: true, updateRate: 0 },
  },
];

/** A manifest case entry. */
export interface GoldenManifestCase {
  id: string;
  family: string;
  variant: string;
  json: string;
  cbor: string;
  uuidPointers: readonly string[];
  /**
   * True when the JSON golden is a documented surrogate for a CBOR-only
   * value, such as the hex string that stands in for a byte string.
   */
  jsonSurrogate: boolean;
}

/** The corpus manifest. */
export interface GoldenManifest {
  schemaVersion: number;
  description: string;
  cases: GoldenManifestCase[];
}

/** Render the corpus bytes without writing them to disk. */
export function renderGoldenCorpus(): { manifest: GoldenManifest; files: Map<string, Buffer> } {
  const files = new Map<string, Buffer>();
  for (const goldenCase of GOLDEN_CASES) {
    files.set(
      `${goldenCase.id}.json`,
      Buffer.from(goldenCase.json ?? JSON.stringify(goldenCase.value), "utf8"),
    );
    files.set(`${goldenCase.id}.cbor`, Buffer.from(encodeDeterministicCBOR(goldenCase.value, goldenCase.uuidPointers)));
  }
  const manifest: GoldenManifest = {
    schemaVersion: 1,
    description:
      "Frozen coaty/3 JSON and axoloty/1 CBOR goldens. Regenerate only in a dedicated, reviewed wire change.",
    cases: GOLDEN_CASES.map(goldenCase => ({
      id: goldenCase.id,
      family: goldenCase.family,
      variant: goldenCase.variant,
      json: `${goldenCase.id}.json`,
      cbor: `${goldenCase.id}.cbor`,
      uuidPointers: goldenCase.uuidPointers,
      jsonSurrogate: goldenCase.jsonSurrogate ?? false,
    })),
  };
  files.set("manifest.json", Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, "utf8"));
  return { manifest, files };
}

/** Write the frozen corpus and manifest into `goldenDir`. */
export function writeGoldenCorpus(goldenDir: string): GoldenManifest {
  const { manifest, files } = renderGoldenCorpus();
  fs.mkdirSync(goldenDir, { recursive: true });
  for (const [name, contents] of files) fs.writeFileSync(path.join(goldenDir, name), contents);
  return manifest;
}

/** Resolve the repository root from this module's location (`src/` or `dist/`). */
export function repositoryRootFromModule(moduleUrl: string): string {
  return path.resolve(path.dirname(new URL(moduleUrl).pathname), "../../../../..");
}
