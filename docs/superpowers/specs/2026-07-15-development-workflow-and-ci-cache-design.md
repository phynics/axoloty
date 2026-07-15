<!-- Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License. -->

# Development Workflow and CI Cache Design

**Date:** 2026-07-15
**Status:** Approved

## Purpose

Axoloty uses a development container to define its Linux Swift environment,
but the Makefile currently creates a new disposable Podman or Docker container
for most commands. The two entry points do not share one container lifecycle.
The Makefile also mounts one writable SwiftPM `.build` directory across all
worktrees. This improves incremental builds but allows concurrent worktrees to
mutate the same compiler database and build products.

GitHub Actions compounds the problem. Pull-request CI runs overlapping Swift
builds in separate wire-compatibility, build-and-test, and coverage jobs. Each
job restores and later attempts to save the complete `.build` tree. In the
checkout inspected for this design, that tree is 833 MB: approximately 361 MB
of dependency repositories and checkouts and 462 MB of mutable compiler
output. The cache key includes source hashes, so ordinary commits continually
create large cache entries. The development image is separately serialized as
a Docker tarball and stored in the Actions cache.

The primary optimization objective is to minimize total GitHub-hosted runner
minutes. Shortest pull-request wall-clock latency is secondary. Local workflow
changes must preserve the repository rule that native host Swift commands are
unsupported and Makefile targets remain canonical.

## Goals

- Execute every required pull-request test exactly once.
- Remove duplicate Swift compilation across pull-request jobs.
- Use the same immutable environment in devcontainers and CI.
- Avoid downloading unchanged Swift dependencies in new worktrees.
- Give each worktree independent mutable compiler output.
- Preserve Podman and Docker support without requiring host Swift.
- Turn the existing coverage data into useful, low-noise feedback.
- Reduce Actions cache churn and exposure to cache poisoning.
- Keep clean, cache-free builds fully supported.
- Measure total runner-minute improvement rather than assuming a cache helps.

## Non-goals

- A self-hosted GitHub Actions runner.
- Maximum pull-request parallelism.
- Automatic mutation of the committed coverage baseline.
- A third-party coverage service or write-enabled coverage bot.
- Sharing one writable compiler database between worktrees.
- Making changed-line coverage a required gate.
- Replacing SwiftPM or introducing a remote compiler cache in the first
  implementation.

## Considered approaches

### Consolidated CI with split caches

One pull-request job runs the support tests and one coverage-enabled complete
Swift test pass. CI caches dependency data rather than the complete build
tree. Local worktrees share dependency downloads and retain independent build
directories. A prebuilt image is consumed by CI and devcontainers.

This approach best matches the runner-minute objective and is selected.

### Parallel jobs with improved cache keys

Keeping the wire, full-test, and coverage jobs would preserve short feedback
latency, but each job would still compile a substantial portion of the same
dependency graph. Passing compiler artifacts between jobs would add upload,
download, and extraction work, and coverage-instrumented objects are not a
drop-in replacement for normal objects. This approach does not address the
main source of billed minutes.

### Persistent self-hosted runner

A self-hosted runner could retain images and build output without hosted
runner charges. It would also add patching, availability, credential,
untrusted-change, and isolation responsibilities. It may be reconsidered only
after the workflow itself no longer duplicates work.

## Architecture

The design has four distinct state boundaries:

1. The development image contains the pinned Swift toolchain and system
   packages. It is immutable at use time.
2. The SwiftPM dependency cache contains downloaded repositories and other
   dependency-fetch state. It is reusable across worktrees with the same cache
   compatibility key.
3. Each worktree owns its `.build` scratch directory, compiler database,
   products, coverage profiles, and indexes.
4. Test evidence under `.testing` belongs to the current checkout or CI run
   and is never used as executable input by another run.

Mutable state never crosses a trust or concurrency boundary merely to save a
few seconds. Dependency and compiler caches are separate because they have
different invalidation rules and risk profiles.

## Canonical container environment

The development Dockerfile is built by a dedicated trusted workflow only when
its inputs change or when a scheduled security refresh is requested. The
workflow publishes the image to GHCR with a human-readable version tag,
provenance, and an SBOM. CI and `devcontainer.json` consume an immutable image
digest. The current `actions/cache` Docker tarball is removed.

The image build is the only workflow that needs `packages: write`. Ordinary CI
has `contents: read` and read access to the published image. If GHCR is
unavailable, local development may build the Dockerfile explicitly. CI fails
instead of silently substituting an unpinned or mutable image.

Publishing a replacement image does not mutate repository source. The
resulting digest is promoted through a separate reviewed repository change
that updates the devcontainer and CI image reference. Until that change lands,
consumers continue using the previous digest. A pull request that modifies the
Dockerfile validates a locally built candidate image before it can be
published from `master`.

The runtime image provides a non-root development user. Package installation
and other privileged changes occur only while building the image. The
devcontainer sets an explicit environment marker so Make can distinguish an
in-container invocation without guessing from `/.dockerenv`.

## Local execution model

Makefile targets remain the public interface. Their execution strategy depends
on context:

- Inside the Axoloty devcontainer, a Make target invokes Swift directly.
- Outside it, Make uses the already-running devcontainer when available.
- An explicit Podman or Docker disposable-container path remains available for
  automation and recovery.
- Make never invokes native host Swift.

The devcontainer and fallback runtime use identical workspace paths and cache
arguments. `make build`, `make test`, `make ci`, `make shell`, and `make docs`
therefore no longer define a second environment accidentally.

Every worktree keeps its ignored `.build` directory inside that worktree. A
named volume or host cache directory provides the shared SwiftPM dependency
cache. The compatibility namespace includes at least:

- Swift toolchain version;
- operating system and architecture;
- development image digest;
- `Package.resolved` hash; and
- any SwiftPM flags that alter dependency or manifest caching.

Dependency-cache population is serialized with a lock stored beside the
shared cache unless the selected SwiftPM version provides and documents an
equivalent cross-process guarantee. Cache-hit reads may proceed concurrently.

`make worktree-bootstrap` creates required directories, validates the
environment, and resolves dependencies through the shared cache. Compilation
remains lazy. `make worktree-warm` is an explicit opt-in for users who want the
new worktree compiled before beginning work.

Copy-on-write seeding from a compatible `master` build is deferred. It may be
added only if measurement shows that dependency caching and normal incremental
builds are insufficient. A future seed must match the toolchain, image,
lockfile, build mode, and base commit; it must use a true copy-on-write clone,
never writable hard links.

## Pull-request CI data flow

Required pull-request CI becomes one job with this sequence:

1. Check out the proposed merge revision.
2. Restore the dependency-only cache.
3. Resolve the locked dependency graph explicitly.
4. Verify that resolution did not modify `Package.resolved`.
5. Disable automatic dependency resolution for subsequent build and test
   commands.
6. Run support-harness self-tests and test-tier validation.
7. Start the isolated local Mosquitto broker.
8. Run `swift test --enable-code-coverage` once with the existing deterministic
   fuzz defaults.
9. Export source coverage, apply the aggregate ratchet, and generate the
   informational coverage summary.
10. Upload diagnostic evidence when a step fails.

The coverage-enabled `swift test` builds the package and runs all Swift tests,
including the unit, module, deterministic fuzz, offline wire, and integration
tests. Separate `swift build`, uninstrumented full-test, and filtered offline
wire jobs would repeat work and are removed from required PR CI.

`make ci` reproduces this sequence locally and is the canonical CI entry point.
The test-tier contract is updated to express that logical tiers may share one
physical Swift test invocation while remaining independently documented.

Workflow-level concurrency groups use the workflow name and pull-request ref.
A new commit cancels the obsolete run. Direct `master` runs are not canceled by
an unrelated pull request.

Documentation, Pages deployment, nightly fuzz campaigns, and scheduled live
wire compatibility remain separate workflows because their cadence, permissions,
or external tooling differs from required PR CI. They reuse the pinned image
and compatible dependency cache without restoring PR compiler output.

## GitHub Actions cache policy

CI initially caches SwiftPM dependency-fetch state only. The key is stable for
an unchanged dependency graph and includes the environment compatibility
fields described above. Source-file hashes are intentionally absent because
source changes do not invalidate downloaded repositories.

Pull-request workflows use restore-only cache access. A trusted `master` build
populates or refreshes shared entries. Cache paths contain no tokens,
credentials, SwiftPM security configuration, build products, test executables,
or user-controlled shell state.

Compiled-output caching is disabled initially. It may be introduced later only
after cold and warm measurements include cache compression, upload, download,
and extraction time and demonstrate a reduction in total runner minutes. Cache
size and eviction behavior are part of that decision, not merely compile time.

## Coverage reporting

The committed aggregate coverage baseline remains the only coverage gate. At
the time of this design it records 3,163 covered lines out of 7,997 production
lines, or 39.5523%. CI continues to reject an aggregate regression beyond the
approved tolerance.

Changed-line coverage is informational. The coverage reporter combines LLVM's
exported execution counts with the pull-request diff and writes a GitHub job
summary containing:

- current aggregate coverage;
- committed baseline and percentage-point delta;
- covered and executable changed-line counts;
- changed-line coverage percentage; and
- files with the largest relevant changes or regressions.

Uncovered changed executable lines produce native GitHub workflow warnings,
limited to the first 20 annotations to avoid noise. The warnings and job
summary need no pull-request write permission. CI does not create or update PR
comments.

The small normalized `report.json` is uploaded on every run with short
retention. The raw LLVM export, coverage profiles, and a browsable HTML report
are produced and uploaded only on coverage failure or explicit manual runs.
This retains useful diagnostics without spending artifact storage and runner
time on every successful change.

The existing absolute per-file covered-line rule is replaced. It can report a
false regression when tested code is deleted and can overlook newly added
untested lines while the old covered count remains unchanged. Informational
diff coverage expresses the per-change signal; the aggregate ratchet remains
the enforcement backstop.

An explicit `make coverage-baseline` target generates a candidate normalized
baseline from a successful local run. CI never mutates or commits the baseline.
Any baseline change is reviewed like source code.

## Security hardening

- Pin every external GitHub Action to a verified full commit SHA.
- Declare `contents: read` as the default workflow permission and grant write
  scopes only to the specific image and Pages jobs that require them.
- Consume the development image by digest and retain its SBOM and provenance.
- Configure Dependabot for GitHub Actions and Docker inputs.
- Keep pull-request cache use restore-only and exclude executable output.
- Verify `Package.resolved` after the explicit resolution phase.
- Disable automatic dependency resolution during compilation and tests.
- Remove the current coverage command's `2>/dev/null` so compiler and
  instrumentation diagnostics remain visible.
- Use explicit job and long-running test deadlines.
- Upload logs and reproducer evidence only as required by the existing artifact
  contract.
- Do not use `pull_request_target` to build or execute proposed changes.
- Keep image publishing, Pages deployment, and ordinary CI permission domains
  separate.

## Failure handling and recovery

- A cache miss performs a clean dependency fetch and creates no correctness
  difference.
- A corrupt local dependency cache can be removed independently of every
  worktree's compiler output.
- A corrupt worktree build can be removed without discarding shared downloads.
- Concurrent worktrees cannot mutate each other's build databases or products.
- Failure to pull the pinned image stops CI with a clear infrastructure error.
- Local users may explicitly rebuild the image from the repository Dockerfile.
- A clean checkout with no image or caches remains a supported bootstrap path.
- Coverage reporting failure fails the coverage step rather than hiding a
  malformed or incomplete report.
- Superseded pull-request runs are canceled; nightly and release evidence runs
  are not canceled by ordinary source pushes.

## Validation strategy

Before changing behavior, record representative existing CI durations and
local cold/warm timings. Validation then covers:

- clean image build and clean dependency resolution;
- dependency-cache hit and miss paths;
- locked resolution detecting a modified `Package.resolved`;
- local invocation inside and outside the devcontainer;
- Podman and Docker fallback execution;
- two worktrees building concurrently with separate `.build` directories;
- one complete coverage-enabled Swift test pass exercising every required
  Swift test tier;
- support test and test-tier validation execution;
- coverage summary, diff calculation, annotation cap, and malformed LLVM input;
- aggregate ratchet pass and failure behavior;
- cache corruption recovery;
- pinned-image pull failure behavior; and
- workflow permission and action-pin review.

The coverage reporter receives unit tests for path normalization, executable
changed-line calculation, additions and deletions, renamed files, aggregate
deltas, annotation limiting, and empty diffs.

Total runner minutes are compared on identical revisions and cache states over
at least three old-workflow and three new-workflow runs. The median sum of all
job durations must decrease by at least 30%. A faster individual step does not
establish success.

## Staged rollout

1. Add timing evidence, consolidate `make ci`, and add informational coverage
   reporting without changing the workflow topology.
2. Replace PR jobs with the single canonical CI job and add concurrency
   cancellation.
3. Replace full `.build` caches with the dependency-only policy and compare
   measured cold and warm totals.
4. Publish the prebuilt image and replace the Docker-tar cache with the
   digest-pinned image.
5. Unify devcontainer-aware Make execution and introduce the per-worktree
   build/shared-dependency cache split.
6. Add worktree bootstrap and optional warming commands.
7. Reconsider compiler-artifact caching or copy-on-write seeding only if the
   collected measurements justify the complexity.

Each stage remains independently reversible and preserves a cache-free path.

## Acceptance criteria

- Every currently required pull-request test runs exactly once.
- Required PR CI uses one Swift compilation/test job.
- Median total PR runner minutes decrease by at least 30% under the validation
  procedure above.
- A valid shared cache prevents repeat dependency downloads.
- CI does not cache `.build` compiler products or a Docker image tarball.
- Two worktrees can build concurrently without sharing mutable compiler state.
- `make build`, `make test`, and `make ci` work inside and outside the
  devcontainer without host Swift.
- Docker and Podman fallback paths remain supported.
- CI and devcontainers consume the same image digest.
- External actions are SHA-pinned and ordinary CI has read-only permissions.
- Coverage summaries are always visible, changed-line coverage remains
  informational, and only the aggregate ratchet can fail on coverage policy.
- The committed baseline can change only through an explicit reviewed edit.
- Docs, Pages, nightly fuzzing, and scheduled live compatibility preserve their
  established behavior and cadence.
