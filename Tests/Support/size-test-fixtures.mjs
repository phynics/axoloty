// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import fs from "node:fs";

const [packagePath, outputPath, sourcePath, tamperedPath] = process.argv.slice(2);
const packageText = fs.readFileSync(packagePath, "utf8");
const injected = packageText.replace(
  'name: "AxolotyWireConsumer",\n            dependencies: [\n                .product(name: "AxolotyWire", package: "AxolotyWire"),\n            ]',
  'name: "AxolotyWireConsumer",\n            dependencies: [\n                .product(name: "AxolotyWire", package: "AxolotyWire"),\n                .product(name: "MQTTNIO", package: "mqtt-nio"),\n            ]',
);
fs.writeFileSync(outputPath, injected);

if (sourcePath && tamperedPath) {
  const baseline = JSON.parse(fs.readFileSync(sourcePath, "utf8"));
  baseline.consumers.AxolotyWireConsumer.unstrippedBytes += 500;
  fs.writeFileSync(tamperedPath, `${JSON.stringify(baseline, null, 2)}\n`);
}
