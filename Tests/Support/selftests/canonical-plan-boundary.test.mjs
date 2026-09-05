// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

const root = path.resolve(new URL("../../..", import.meta.url).pathname);
const toolingRoot = path.join(root, "Tools/AxolotyTooling");
const resolverPath = "Tools/AxolotyTooling/Manifest/CanonicalTestPlanResolver.swift";
const plannerPath = "Tools/AxolotyTooling/Check/AxolotyCheckPlanning.swift";
const manifestContractsPath = "Tools/AxolotyTooling/Manifest/CanonicalTestManifestContracts.swift";

function swiftFiles(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return swiftFiles(entryPath);
    return entry.name.endsWith(".swift") ? [entryPath] : [];
  });
}

function sourceCodeOnly(source) {
  let result = "";
  let state = "code";
  let index = 0;
  let blockDepth = 0;
  let delimiter = "";
  while (index < source.length) {
    const pair = source.slice(index, index + 2);
    if (state === "line-comment" && source[index] === "\n") {
      state = "code";
      result += "\n";
      index += 1;
    } else if (state === "code" && pair === "//") {
      state = "line-comment";
      result += "  ";
      index += 2;
    } else if (state === "code" && pair === "/*") {
      state = "block-comment";
      blockDepth = 1;
      result += "  ";
      index += 2;
    } else if (state === "block-comment" && pair === "/*") {
      blockDepth += 1;
      result += "  ";
      index += 2;
    } else if (state === "block-comment" && pair === "*/") {
      blockDepth -= 1;
      state = blockDepth === 0 ? "code" : state;
      result += "  ";
      index += 2;
    } else if (state === "code" && source.startsWith('"""', index)) {
      state = "string";
      delimiter = '"""';
      result += "   ";
      index += 3;
    } else if (state === "code" && source[index] === '"') {
      state = "string";
      delimiter = '"';
      result += " ";
      index += 1;
    } else if (state === "string" && source.startsWith(delimiter, index)) {
      state = "code";
      result += " ".repeat(delimiter.length);
      index += delimiter.length;
    } else if (state === "string" && source[index] === "\\") {
      result += "  ";
      index += Math.min(2, source.length - index);
    } else {
      result += state === "code" || source[index] === "\n" ? source[index] : " ";
      index += 1;
    }
  }
  return result;
}

function lineNumber(source, index) {
  return source.slice(0, index).split("\n").length;
}

function planCalls(source) {
  const calls = [];
  const marker = "AxolotyCheckPlan(";
  let start = source.indexOf(marker);
  while (start >= 0) {
    let depth = 1;
    let index = start + marker.length;
    while (index < source.length && depth > 0) {
      if (source[index] === "(") depth += 1;
      if (source[index] === ")") depth -= 1;
      index += 1;
    }
    calls.push({ start, text: source.slice(start, index) });
    start = source.indexOf(marker, index);
  }
  return calls;
}

export function findCanonicalPlanBoundaryViolations(files) {
  const violations = [];
  let resolverDeclarationCount = 0;
  let includesResolverFile = false;
  for (const file of files.toSorted((left, right) => left.path.localeCompare(right.path))) {
    const source = sourceCodeOnly(file.source);
    includesResolverFile ||= file.path === resolverPath;
    if (file.path !== resolverPath) {
      for (const match of source.matchAll(/\.\s*decode\s*\(\s*AxolotyCanonicalTestManifest\s*\.\s*self/g)) {
        violations.push(`${file.path}:${lineNumber(source, match.index)}: manifest loading belongs to the canonical resolver`);
      }
      for (const match of source.matchAll(/\b(?:loadDefault|checkNode)\s*\(/g)) {
        violations.push(`${file.path}:${lineNumber(source, match.index)}: canonical plan materialization belongs to the canonical resolver`);
      }
    }
    if (file.path === manifestContractsPath) {
      for (const match of source.matchAll(/\bcommandPlan\s*\(/g)) {
        violations.push(`${file.path}:${lineNumber(source, match.index)}: manifest contracts must remain data-only`);
      }
    }
    for (const match of source.matchAll(/\b(struct|class|actor|protocol)\s+(\w*Canonical\w*Plan\w*Resolv\w*)/g)) {
      const allowed = file.path === resolverPath
        && match[1] === "struct"
        && match[2] === "AxolotyCanonicalTestPlanResolver";
      if (allowed) {
        resolverDeclarationCount += 1;
      } else {
        violations.push(`${file.path}:${lineNumber(source, match.index)}: the canonical plan resolver must remain one concrete type`);
      }
    }
    for (const call of planCalls(source)) {
      if (/\bschemaVersion\s*:/.test(call.text)) {
        violations.push(`${file.path}:${lineNumber(source, call.start)}: AxolotyCheckPlan schema is fixed at version 1`);
      }
      if (file.path !== resolverPath && file.path !== plannerPath) {
        violations.push(`${file.path}:${lineNumber(source, call.start)}: check-plan construction belongs to the resolver and dependency planner`);
      }
    }
  }
  if (includesResolverFile && resolverDeclarationCount !== 1) {
    violations.push(`${resolverPath}:1: expected exactly one AxolotyCanonicalTestPlanResolver struct`);
  }
  return violations;
}

test("canonical plan boundary accepts the single resolver owner", () => {
  const files = [
    { path: resolverPath, source: "struct AxolotyCanonicalTestPlanResolver {}\nJSONDecoder().decode(AxolotyCanonicalTestManifest.self, from: data)\nAxolotyCheckPlan(nodes: nodes)" },
    { path: plannerPath, source: "AxolotyCheckPlan(nodes: nodes)" },
  ];
  assert.deepEqual(findCanonicalPlanBoundaryViolations(files), []);
});

test("canonical plan boundary rejects a second manifest loader", () => {
  const violations = findCanonicalPlanBoundaryViolations([{
    path: "Tools/AxolotyTooling/Dispatcher.swift",
    source: "let decoder = JSONDecoder()\ndecoder.decode(\n  AxolotyCanonicalTestManifest.self,\n  from: data\n)",
  }]);
  assert.equal(violations.length, 1);
});

test("canonical plan boundary rejects explicit plan schemas", () => {
  const violations = findCanonicalPlanBoundaryViolations([{
    path: resolverPath,
    source: "struct AxolotyCanonicalTestPlanResolver {}\nAxolotyCheckPlan(\n  schemaVersion: manifest.schemaVersion,\n  nodes: nodes\n)",
  }]);
  assert.equal(violations.length, 1);
});

test("canonical plan boundary ignores comments and string literals", () => {
  const violations = findCanonicalPlanBoundaryViolations([{
    path: "Tools/AxolotyTooling/Dispatcher.swift",
    source: '// JSONDecoder().decode(AxolotyCanonicalTestManifest.self, from: data)\nlet example = "AxolotyCheckPlan(schemaVersion: 2, nodes: [])"',
  }]);
  assert.deepEqual(violations, []);
});

test("canonical plan boundary rejects alternate materializers and resolver abstractions", () => {
  const violations = findCanonicalPlanBoundaryViolations([{
    path: "Tools/AxolotyTooling/Manifest.swift",
    source: `
      protocol CanonicalTestPlanResolving {}
      extension AxolotyCanonicalTestNode {
        func checkNode() -> AxolotyCheckNode { fatalError() }
      }
      AxolotyCanonicalTestManifest.loadDefault()
    `,
  }]);
  assert.equal(violations.length, 3);
});

test("canonical plan boundary rejects resolver abstractions beside the concrete owner", () => {
  const violations = findCanonicalPlanBoundaryViolations([{
    path: resolverPath,
    source: `
      struct AxolotyCanonicalTestPlanResolver {}
      protocol CanonicalTestPlanResolving {}
    `,
  }]);
  assert.equal(violations.length, 1);
});

test("canonical plan boundary rejects plan construction outside its two owners", () => {
  const violations = findCanonicalPlanBoundaryViolations([{
    path: "Tools/AxolotyTooling/Dispatcher.swift",
    source: "AxolotyCheckPlan(nodes: manifest.nodes.map(convert))",
  }]);
  assert.equal(violations.length, 1);
});

test("repository obeys the canonical plan boundary", () => {
  const files = swiftFiles(toolingRoot).map(file => ({
    path: path.relative(root, file).split(path.sep).join("/"),
    source: fs.readFileSync(file, "utf8"),
  }));
  assert.deepEqual(findCanonicalPlanBoundaryViolations(files), []);
});
