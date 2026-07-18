#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu

output_dir="${1:?usage: write-docs-root-redirect.sh <docc-output-dir>}"

[ -d "$output_dir" ] || { echo "error: $output_dir does not exist" >&2; exit 1; }

cat > "$output_dir/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Axoloty Documentation</title>
<meta http-equiv="refresh" content="0; url=documentation/axoloty/">
<script>location.replace("documentation/axoloty/")</script>
</head>
<body>
<p>Redirecting to <a href="documentation/axoloty/">Axoloty documentation</a>.</p>
</body>
</html>
HTML
