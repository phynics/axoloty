# Development Workflow and CI Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce total CI runner minutes and make local worktrees reuse dependency downloads without sharing mutable Swift compiler output.

**Architecture:** Make remains the public entry point, but routes Swift commands directly inside the devcontainer and mounts separate per-worktree build and shared SwiftPM dependency paths outside it. Pull-request CI becomes one coverage-backed Swift job with a dependency-only cache. A trusted image workflow publishes the same container environment consumed by CI and devcontainers.

**Tech Stack:** GNU Make, Bash, Python 3 standard library, Swift Package Manager 6.3, Podman/Docker, GitHub Actions, GHCR, LLVM coverage export.

## Global Constraints

- Never run native host Swift; use Make targets through the development container.
- Preserve Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`) and do not add XCTest.
- Keep `Package.resolved` authoritative and fail if explicit resolution changes it.
- Keep package errors and public Swift API behavior unchanged.
- Use full-length commit SHAs for external GitHub Actions.
- Ordinary CI has read-only repository/package permissions; image publishing is isolated.
- Keep unrelated T039 working-tree changes in the main checkout untouched.
- Use Conventional Commits and no bot co-author trailers.

---

### Task 1: Separate SwiftPM dependency cache from worktree build output

**Files:**
- Modify: `Makefile`
- Modify: `.devcontainer/devcontainer.json`
- Test: `Tests/Support/test_validate_test_tiers.py` indirectly through `make test-support`

**Interfaces:**
- `SPM_CACHE_DIR` is the host/CI dependency cache directory.
- `BUILD_DIR` defaults to the current worktree `.build` directory.
- `make resolve` explicitly resolves dependencies using `SPM_CACHE_DIR`.
- `make worktree-bootstrap` creates cache directories and runs `resolve`.
- `make worktree-warm` explicitly performs a build after bootstrap.
- `AXOLOTY_DEVCONTAINER=1` marks direct in-container execution.

- [x] **Step 1: Add cache variables and shared command helpers.**

Set `BUILD_DIR ?= $(CURDIR)/.build` and derive `SPM_CACHE_DIR` from the
toolchain namespace under `$(HOME)/.cache/coaty-swift/swiftpm/` unless CI or a
caller overrides it. Mount both paths for disposable containers. Define the
SwiftPM option fragments once so every build/test/docs command receives the
same `--cache-path` and `--disable-automatic-resolution` policy after resolve.

- [x] **Step 2: Add explicit resolution and worktree targets.**

Add `resolve`, `worktree-bootstrap`, and `worktree-warm` targets. Bootstrap
creates the dependency and build directories, acquires a lock file around
cache population, runs `swift package resolve --cache-path ...`, then verifies
`git diff --exit-code -- Package.resolved`. Warm depends on bootstrap and runs
the normal build. Keep compilation lazy for bootstrap.

- [x] **Step 3: Make in-container execution direct and retain fallback.**

When `AXOLOTY_DEVCONTAINER=1`, run Swift commands in the current container
without nesting Podman/Docker. Otherwise keep the existing disposable runtime
path with both mounts. Set the marker and cache mounts in
`devcontainer.json`; do not infer container state from `/.dockerenv`.

- [x] **Step 4: Apply the helper to every Swift target.**

Update `build`, `test`, focused test targets, wire tests, observation tests,
coverage, and docs to use the shared command helper. Preserve broker startup,
fuzz environment defaults, and existing target names. Keep `test-fast` as a
convenience target but do not use it as the consolidated CI implementation.

- [x] **Step 5: Make `ci` one physical Swift pass.**

Change `ci` to run `test-support` followed by `coverage-check`; retain
`ci-fast` and the tier-specific targets for local diagnosis. Add help text for
the new cache and bootstrap variables.

- [x] **Step 6: Run the support contract tests.**

Run:

```sh
make test-support
```

Expected: all Python/shell self-tests pass and tier validation reports the
existing tier contract as valid.

- [x] **Step 7: Commit the cache/runtime boundary.**

```sh
git add Makefile .devcontainer/devcontainer.json
git commit -m "build: separate SwiftPM and worktree caches"
```

### Task 2: Add useful, informational coverage reporting

**Files:**
- Create: `Tests/Support/coverage_report.py`
- Modify: `Tests/Support/coverage_ratchet.py`
- Modify: `Tests/Support/test_coverage_ratchet.py`
- Create: `Tests/Support/test_coverage_report.py`
- Modify: `Makefile`

**Interfaces:**
- `coverage_report.py export REPORT DIFF [--baseline BASELINE] [--annotation-limit N]`
  prints a Markdown summary and optionally appends to `$GITHUB_STEP_SUMMARY`.
- The reporter emits at most 20 native `::warning` annotations for uncovered
  changed executable lines.
- `coverage_ratchet.evaluate` enforces only the aggregate tolerance; per-file
  data remains available for reporting.

- [x] **Step 1: Write failing coverage-report tests.**

Use synthetic `llvm-cov export` JSON and unified diffs to test source-path
normalization, covered executable lines, additions, deletions, renamed files,
empty diffs, aggregate delta, top file regressions, annotation limiting, and
malformed JSON.

- [x] **Step 2: Run the new tests and confirm failure.**

Run:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest Tests/Support/test_coverage_report.py -v
```

Expected: failure because the reporter module and functions do not yet exist.

- [x] **Step 3: Implement the standard-library reporter.**

Parse LLVM segments by source file and line, treating a line as covered when
any executable segment on that line has a positive count. Parse `@@ -old
+new,count @@` hunks, intersect changed lines with executable lines, and emit
aggregate, changed-line, and per-file regression data. Keep output stable and
cap annotations at 20.

- [x] **Step 4: Replace the absolute per-file ratchet.**

Remove the rule that fails when an existing file’s absolute covered-line count
decreases. Retain the aggregate percentage-point tolerance. Update the existing
unit tests to prove deleted tested code does not fail and aggregate drops still
fail.

- [x] **Step 5: Wire reporting into `make coverage`.**

Stop suppressing coverage command stderr. Export the raw LLVM JSON, write the
normalized `report.json`, and invoke the reporter against a generated diff
file. For local runs use `COVERAGE_DIFF_BASE` when supplied, otherwise compare
`HEAD^` to `HEAD`; in CI the workflow prepares the diff file.

- [x] **Step 6: Run all support tests.**

Run:

```sh
make test-support
```

Expected: existing support tests plus the new reporter tests pass.

- [x] **Step 7: Commit coverage reporting.**

```sh
git add Makefile Tests/Support/coverage_report.py Tests/Support/test_coverage_report.py Tests/Support/coverage_ratchet.py Tests/Support/test_coverage_ratchet.py
git commit -m "ci: expose informational coverage changes"
```

### Task 3: Consolidate required pull-request CI and cache only dependencies

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/actions/setup-container/action.yml`
- Modify: `.github/workflows/docs.yml`
- Modify: `.github/workflows/wire-compatibility.yml`
- Modify: `.github/workflows/fuzz.yml`

**Interfaces:**
- Required PR CI has one job that invokes `make ci`.
- The cache path is `.swiftpm-cache`, keyed by Swift version, runner OS,
  architecture, image identity, and `Package.resolved`.
- `.testing/coverage/report.json` is uploaded on every coverage run; raw
  coverage evidence is retained on failure/manual runs.

- [x] **Step 1: Add workflow-level cancellation and permissions.**

Set `permissions: contents: read` for ordinary CI and use a unique concurrency
group based on workflow and pull-request ref with `cancel-in-progress: true`.
Keep Pages permissions confined to `docs.yml`.

- [x] **Step 2: Replace three Swift CI jobs with one.**

Remove the separate wire, build-and-test, and coverage jobs from `ci.yml`.
Create one Linux job with checkout (`fetch-depth: 0`), image setup, dependency
cache restore, diff preparation, and `make ci CONTAINER_RUNTIME=docker
BUILD_DIR=.build SPM_CACHE_DIR=.swiftpm-cache`.

- [x] **Step 3: Make cache writes trusted and dependency-only.**

Use restore-only behavior for pull requests and save compatible dependency
caches from trusted `master` runs. Remove source hashes and `.build` from cache
paths. Include the Dockerfile/image identity in the key.

- [x] **Step 4: Publish coverage evidence without extra jobs.**

Always upload `report.json` and the text summary with short retention. Upload
raw LLVM JSON, profiles, and HTML only under `failure()` or explicit manual
execution. Do not create PR comments or grant pull-request write permission.

- [x] **Step 5: Migrate docs, scheduled wire, and fuzz cache paths.**

Keep their cadence and test scope unchanged, but cache only `.swiftpm-cache`
with the same compatibility key. Add concurrency cancellation only where
superseding a run is safe; preserve nightly evidence runs.

- [x] **Step 6: Pin every external action.**

Replace version tags in all modified workflows and composite actions with the
verified full commit SHAs for the selected action releases. Keep local actions
as `./.github/actions/...`.

- [x] **Step 7: Run YAML and support checks.**

Run:

```sh
make test-support
git diff --check
```

Expected: support contract passes and the workflow diff has no whitespace
errors.

- [x] **Step 8: Commit CI consolidation.**

```sh
git add .github/actions .github/workflows
git commit -m "ci: consolidate Swift checks and dependency caches"
```

### Task 4: Publish and consume the development image

**Files:**
- Create: `.github/workflows/container-image.yml`
- Modify: `.devcontainer/Dockerfile`
- Modify: `.devcontainer/devcontainer.json`
- Modify: `.github/actions/setup-container/action.yml`
- Create: `.devcontainer/image-lock.json`

**Interfaces:**
- The image workflow publishes `ghcr.io/phynics/axoloty-dev` on Dockerfile/base
  input changes and scheduled security refreshes.
- `image-lock.json` records the reviewed immutable digest and Dockerfile/image
  metadata consumed by local and CI configuration.

- [x] **Step 1: Add a trusted image publish workflow.**

Build with the repository Dockerfile, log in to GHCR using `GITHUB_TOKEN`, push
the content-addressed version tag, and publish an SBOM/provenance artifact.
Grant only `contents: read` and `packages: write`; do not run proposed PR source
with package-write permission.

- [ ] **Step 2: Add the reviewed image lock.**

Record the image reference, digest, Swift version, and Dockerfile hash in
`.devcontainer/image-lock.json`. Consumers use the digest; updating it is a
reviewed repository change and is never performed by CI automatically.

- [x] **Step 3: Align devcontainer and setup action.**

Use the locked image when available. Keep an explicit local Dockerfile build
fallback for developers. CI may use the fallback only during the transition
before the first trusted image is published; after promotion, a missing locked
image is a hard failure.

- [x] **Step 4: Run configuration checks.**

Run:

```sh
make test-support
python3 -m json.tool .devcontainer/devcontainer.json >/dev/null
python3 -m json.tool .devcontainer/image-lock.json >/dev/null
```

- [x] **Step 5: Commit image integration.**

```sh
git add .devcontainer .github/actions/setup-container/action.yml .github/workflows/container-image.yml
git commit -m "ci: publish the pinned development image"
```

### Task 5: Verify, document, and integrate the branch

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md` only if the final Make/devcontainer contract changes
- Modify: `docs/superpowers/plans/2026-07-15-development-workflow-and-ci-cache-plan.md`

- [x] **Step 1: Document local cache controls.**

Document `SPM_CACHE_DIR`, `BUILD_DIR`, `make resolve`,
`make worktree-bootstrap`, and `make worktree-warm`, including how to remove a
corrupt dependency cache without deleting a worktree build.

- [x] **Step 2: Run the full repository verification through Make.**

Run:

```sh
make test-support
make build
make test
make coverage-check
```

Expected: each command exits zero in the pinned container. If the host lacks a
container runtime, report that as an environment blocker rather than running
native Swift.

- [x] **Step 3: Review the complete diff and branch state.**

Run:

```sh
git diff master...HEAD --check
git diff master...HEAD --stat
git status --short
```

Confirm no unrelated files or generated outputs are included.

- [x] **Step 4: Commit documentation and plan completion.**

```sh
git add README.md AGENTS.md docs/superpowers/plans/2026-07-15-development-workflow-and-ci-cache-plan.md
git commit -m "docs: document containerized workflow caches"
```

- [x] **Step 5: Merge into `master`.**

From the clean main checkout, fast-forward or merge the implementation branch
after verifying the final branch tests. Preserve the unrelated T039 edits by
using a non-destructive merge and resolving only implementation-branch files.

- [x] **Step 6: Remove the merged worktree.**

After the merge and final verification:

```sh
git worktree remove .worktree/2026-07-15-workflow
git branch -d codex/2026-07-15-workflow
```

Do not remove the worktree before the merge is confirmed.
