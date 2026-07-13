# Fuzz Campaign Runner Design

## Goal

Provide a reproducible shell-based fuzz campaign runner for the deterministic
XCTest fuzz suite, with useful terminal progress and durable audit artifacts.

## Location and invocation

The runner will live at `Tests/Fuzzing/run-fuzz.sh`, beside the fuzz tests and
following the repository's existing `run-*.sh` convention.

It will support both environments:

- Outside a container, it will use the repository's Makefile/container flow.
- Inside the development container, it will invoke the Swift test command
  directly.

The runtime can be selected explicitly and will otherwise detect Podman or
Docker when running outside a container.

## Campaign controls

The runner will support:

- iteration count per case;
- an explicit comma-separated seed list;
- repetitions per seed;
- output directory;
- continue-on-failure by default;
- optional fail-fast mode;
- a human-readable progress stream and a quiet mode for automation.

Each case will run as an independent test process so its exit status, duration,
seed, and log remain attributable to one exact input configuration.

## Audit artifacts

Every campaign will create a timestamped directory containing:

- `manifest.json`: UTC timestamps, git revision/status, execution mode,
  runtime, command arguments, iteration count, seeds, repetitions, and host
  metadata;
- one complete log per seed/repetition;
- `summary.tsv` with case, seed, repetition, duration, and exit status;
- `campaign.log` containing the streamed combined output.

The exact seed and command for every case will be recorded in its case log so
failures can be replayed. Output directories will be created under an ignored
artifact path by default, while allowing a caller-provided path for CI or
release retention.

## Make integration and documentation

Add a `fuzz-long` Makefile target that forwards Make variables to the runner,
while retaining `make test-fuzz` for the existing short deterministic check.
Document short, multi-seed, and replay workflows in `Tests/TESTING.md`.

## Verification

Verify shell syntax, help output, a small one-seed campaign, multi-seed
continuation after a failing case where practical, manifest/summary contents,
and the existing test-tier metadata validator. Swift execution must remain
containerized according to `AGENTS.md`.
