#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Print the container environment allowlist for an axoloty-tool command.
# The allowlist lives in Tests/Support/test-tiers.json under
# toolContainerEnv; the tier validator enforces its shape.
set -eu

command=${1:?usage: tool-container-env.sh <command-id>}
root_dir=$(cd "$(dirname "$0")/../.." && pwd)

node -e '
const fs = require("node:fs");
const [manifestPath, command] = process.argv.slice(1);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const names = manifest.toolContainerEnv?.[command];
if (!Array.isArray(names) || names.length === 0) {
	console.error(`toolContainerEnv: no allowlist for ${command}`);
	process.exit(1);
}
console.log(names.join(" "));
' "$root_dir/Tests/Support/test-tiers.json" "$command"
