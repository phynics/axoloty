// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

const manifest = JSON.parse(fs.readFileSync("Tests/Support/test-tiers.json", "utf8"));
const nodes = new Map(manifest.nodes.map(node => [node.id, node]));
const preparation = nodes.get("wire-live-prepare");

test("live wire plan prepares its shared images and test products once", () => {
  assert.ok(preparation, "missing wire-live-prepare node");
  assert.equal(preparation.command.executable, "Tests/Support/WireCompatibility/Live/prepare-live-suite.sh");
  assert.deepEqual(nodes.get("wire-capture-advertise").dependencies, ["wire-live-prepare"]);
  assert.equal(nodes.has("wire-subject-build"), false, "separate subject build should be folded into preparation");
});

test("live wire scenarios consume prepared assets without rebuilding", () => {
  const scenarioRoots = [
    "Tests/Support/WireCompatibility/Live",
    "Tests/Support/WireCompatibility/Reverse",
    "Tests/Support/WireCompatibility/IO/Live",
    "Tests/Support/WireCompatibility/Lifecycle/Live",
  ];
  const preparationPath = path.normalize("Tests/Support/WireCompatibility/Live/prepare-live-suite.sh");

  for (const root of scenarioRoots) {
    for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
      if (!entry.isFile() || !entry.name.endsWith(".sh")) continue;
      const filename = path.join(root, entry.name);
      if (path.normalize(filename) === preparationPath) continue;
      const source = fs.readFileSync(filename, "utf8");
      assert.doesNotMatch(source, /(?:podman|runtime) build -t/, `${filename} rebuilds a shared image`);
      assert.doesNotMatch(source, /swift build/, `${filename} rebuilds shared Swift test products`);
      if (source.includes("swift test")) {
        assert.match(source, /--skip-build/, `${filename} does not consume the prepared tests`);
        assert.match(source, /--scratch-path \/swift-build/, `${filename} uses a different Swift scratch path`);
        assert.match(source, /\$BUILD_DIR:\/swift-build/, `${filename} does not mount the prepared scratch path`);
      }
    }
  }
});
