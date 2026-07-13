# Fuzz Campaign Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a container-aware, reproducible fuzz campaign runner with streamed progress and audit artifacts.

**Architecture:** `Tests/Fuzzing/run-fuzz.sh` owns campaign orchestration and runs one Swift Testing process per seed/repetition. It invokes the existing container image outside containers and Swift directly inside containers, writing a manifest, per-case logs, a combined log, and a summary. Make and documentation expose the runner without changing the existing short fuzz target.

**Tech Stack:** Bash, SwiftPM/Swift Testing, Podman or Docker, POSIX text utilities for JSON and TSV audit metadata.

## Global Constraints

- Swift commands must run through the containerized Makefile flow unless already inside the development container.
- Existing `make test-fuzz` behavior and environment variables remain supported.
- Generated campaign artifacts must not become tracked source files.
- Failures are recorded and do not stop later cases unless fail-fast is requested.

### Task 1: Add the campaign runner

**Files:**
- Create: `Tests/Fuzzing/run-fuzz.sh`
- Create: `Tests/Fuzzing/.gitignore`

- [ ] Parse iterations, seeds, repetitions, output, runtime, image, mode, fail-fast, and help options.
- [ ] Detect container mode and run each case with its exact seed and iteration count.
- [ ] Record manifest metadata, raw per-case logs, combined output, and tab-separated results.
- [ ] Return nonzero when any case fails while still continuing by default.

### Task 2: Integrate Make and documentation

**Files:**
- Modify: `Makefile`
- Modify: `Tests/TESTING.md`

- [ ] Add `make fuzz-long` forwarding `FUZZ_*` variables to the runner.
- [ ] Document multi-seed, repetition, audit-output, and replay commands.

### Task 3: Verify the harness

**Files:** None.

- [ ] Run shell syntax and help checks.
- [ ] Run the metadata validator.
- [ ] Run a small containerized campaign and inspect its manifest, summary, and logs.
- [ ] Run `git diff --check` and confirm unrelated changes remain unstaged.
