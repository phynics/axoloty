// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import fs from "node:fs";

const [packagePath, outputPath, sourcePath, tamperedPath] = process.argv.slice(2);
const packageText = fs.readFileSync(packagePath, "utf8");
const consumerDependencies = 'name: "AxolotyWireConsumer",\n            dependencies: [\n                "AxolotyWire",\n            ]';
if (!packageText.includes(consumerDependencies)) throw new Error("AxolotyWireConsumer dependency fixture is stale");
const injected = packageText.replace(
  consumerDependencies,
  'name: "AxolotyWireConsumer",\n            dependencies: [\n                "AxolotyWire",\n                .product(name: "MQTTNIO", package: "mqtt-nio"),\n            ]',
);
fs.writeFileSync(outputPath, injected);

if (sourcePath && tamperedPath) {
  const baseline = JSON.parse(fs.readFileSync(sourcePath, "utf8"));
  baseline.consumers.AxolotyWireConsumer.unstrippedBytes += 500;
  fs.writeFileSync(tamperedPath, `${JSON.stringify(baseline, null, 2)}\n`);
}
