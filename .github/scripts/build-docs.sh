#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Build DocC documentation for the Axoloty target and mirror the render to
# the repo-local .build-output directory. Runs inside the development
# container; `make docs` is the only supported entry point.
set -eu

sh .github/scripts/prepare-docc-renderer.sh .build/docc-renderer

hosting_args=""
if [ -n "${DOC_HOSTING_BASE_PATH:-}" ]; then
	hosting_args="--hosting-base-path ${DOC_HOSTING_BASE_PATH}"
fi

# swift package --cache-path --disable-automatic-resolution mirrors the
# make-level SWIFT_LOCKED_ARGS contract. DOCC_HTML_DIR points DocC at the
# renderer prepared above; without it the render silently falls back to the
# toolchain default and the preparation step is dead work.
DOCC_HTML_DIR=/workspace/.build/docc-renderer \
swift package --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution generate-documentation --target Axoloty \
	--disable-indexing \
	--transform-for-static-hosting \
	$hosting_args \
	--output-path .build/docc

sh .github/scripts/write-docs-root-redirect.sh .build/docc

rm -rf .build-output/docc
mkdir -p .build-output
cp -R .build/docc .build-output/docc
