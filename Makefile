SHELL := /bin/sh

IMAGE ?= coatyswift-dev
BROKER_NAME ?= coatyswift-mosquitto
CONTAINER_RUNTIME ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
WORKDIR := /workspace
CACHE_NAMESPACE ?= swift-6.3-linux
BUILD_DIR ?= $(HOME)/.cache/coaty-swift/$(CACHE_NAMESPACE)/.build
CONTAINER_MOUNTS := -v "$(CURDIR):$(WORKDIR)" -v "$(BUILD_DIR):$(WORKDIR)/.build"
COMMA := ,

# Hosting base path for static DocC output. Set this to the repository name
# when publishing to a GitHub Pages project site (e.g. "axoloty" for
# https://<user>.github.io/axoloty/). Leave empty for root-hosted output.
DOC_HOSTING_BASE_PATH ?=

.PHONY: help image build test test-unit test-module test-fuzz fuzz-long test-fast test-wire test-wire-live test-wire-all test-support test-observation-linux coverage coverage-check ci-fast ci broker broker-stop shell docs clean

help:
	@printf '%s\n' \
		'make image         Build the Linux Swift development image' \
		'make build         Build Axoloty in the Linux container' \
		'make test          Run the full test suite (starts Mosquitto)' \
		'make test-unit     Run ObjectMatcherTests' \
		'make test-module   Run targeted infrastructure module tests' \
		'make test-fuzz     Run deterministic property/fuzz tests' \
		'make fuzz-long     Run an auditable multi-seed fuzz campaign' \
		'make test-fast     Run unit, module, fuzz, offline wire, and support self-tests' \
		'make test-wire     Run offline wire fixtures and capture tests' \
		'make test-support  Run Python/shell harness self-tests and tier validation' \
 	'make test-observation-linux Run Observation and EventStream tests on Linux' \
 		'make coverage     Run tests with code coverage and report Source/ coverage' \
		'make coverage-check Run coverage and fail if it regresses the baseline' \
		'make test-wire-live Run live CoatyJS compatibility scenarios' \
		'make test-wire-all Run offline and live compatibility suites' \
		'make ci-fast       Run the build and fast test suite' \
		'make ci            Run all pull-request CI checks' \
		'make broker        Start Mosquitto on localhost:1883' \
		'make broker-stop   Stop the background Mosquitto container' \
		'make shell         Open a shell in the Linux container' \
		'make docs          Generate DocC API documentation into .build/docc' \
		'make clean         Remove Swift build artifacts' \
		'' \
		'BUILD_DIR can point at a different persistent SwiftPM cache directory'

image:
	@test -n "$(CONTAINER_RUNTIME)" || (echo 'No podman or docker runtime found' >&2; exit 1)
	@mkdir -p "$(BUILD_DIR)"
	$(CONTAINER_RUNTIME) build -t $(IMAGE) -f .devcontainer/Dockerfile .devcontainer

build: image
	$(CONTAINER_RUNTIME) run --rm $(CONTAINER_MOUNTS) -w $(WORKDIR) $(IMAGE) swift build

test: image
	$(CONTAINER_RUNTIME) run --rm $(CONTAINER_MOUNTS) -w $(WORKDIR) $(IMAGE) \
		sh -c 'pgrep mosquitto >/dev/null 2>&1 || mosquitto -d; swift test'

test-unit: image
	$(CONTAINER_RUNTIME) run --rm $(CONTAINER_MOUNTS) -w $(WORKDIR) $(IMAGE) \
		swift test --filter ObjectMatcherTests

test-module: image
	$(CONTAINER_RUNTIME) run --rm $(CONTAINER_MOUNTS) -w $(WORKDIR) $(IMAGE) swift test --filter CommunicationTopicTests
	$(CONTAINER_RUNTIME) run --rm $(CONTAINER_MOUNTS) -w $(WORKDIR) $(IMAGE) swift test --filter PayloadCoderTests
	$(CONTAINER_RUNTIME) run --rm $(CONTAINER_MOUNTS) -w $(WORKDIR) $(IMAGE) swift test --filter ObjectTypeRegistryTests

test-fuzz: image
	$(CONTAINER_RUNTIME) run --rm $(CONTAINER_MOUNTS) -w $(WORKDIR) \
		-e AXOLOTY_FUZZ_ITERATIONS="$(or $(AXOLOTY_FUZZ_ITERATIONS),250)" \
		-e AXOLOTY_FUZZ_SEED="$(or $(AXOLOTY_FUZZ_SEED),0x41584f4c4f5459)" \
		$(IMAGE) swift test --filter DeterministicFuzzTests

fuzz-long:
	AXOLOTY_FUZZ_ITERATIONS="$(or $(AXOLOTY_FUZZ_ITERATIONS),100000)" \
	AXOLOTY_FUZZ_SEEDS="$(if $(AXOLOTY_FUZZ_SEEDS),$(AXOLOTY_FUZZ_SEEDS),1$(COMMA)2$(COMMA)3$(COMMA)4)" \
	AXOLOTY_FUZZ_REPETITIONS="$(or $(AXOLOTY_FUZZ_REPETITIONS),1)" \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" \
		Tests/Fuzzing/run-fuzz.sh

test-wire: image
	$(CONTAINER_RUNTIME) run --rm $(CONTAINER_MOUNTS) -w $(WORKDIR) $(IMAGE) \
		swift test --filter WireFixtureTests
	$(CONTAINER_RUNTIME) run --rm $(CONTAINER_MOUNTS) -w $(WORKDIR) $(IMAGE) \
		swift test --filter LifecycleCompatibilityScenarioTests

# Harness self-tests for the Python/shell tooling (fuzz runner, capture and
# verifier tools, and the test-tier contract). These are intentionally kept
# separate from protocol-scenario execution and do not invoke Swift.
test-support:
	Tests/Fuzzing/test-run-fuzz.sh
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/WireCompatibility/Capture -p 'test_*.py' -v
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/WireCompatibility/Legacy -p 'test_*.py' -v
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/WireCompatibility/Live -p 'test_*.py' -v
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Support -p 'test_*.py' -v
	python3 Tests/Support/validate_test_tiers.py Tests/Support/test-tiers.json

test-wire-live:
	CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) Tests/WireCompatibility/Live/run-coatyjs-advertise.sh
	CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) Tests/WireCompatibility/Live/run-coatyjs-core.sh
	CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) Tests/WireCompatibility/Lifecycle/Live/run-coatyjs-last-will.sh
	CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) Tests/WireCompatibility/Reverse/run-axoloty-advertise.sh

test-wire-all: test-wire test-wire-live

test-observation-linux: image
	$(CONTAINER_RUNTIME) run --rm $(CONTAINER_MOUNTS) -w $(WORKDIR) $(IMAGE) \
		swift test --filter "ObservationLinuxTests|EventStreamTests"

test-fast: test-unit test-module test-fuzz test-wire test-support

# Source-coverage reporting and ratchet. Runs the full test suite with
# --enable-code-coverage, exports per-file line coverage via llvm-cov, and
# writes machine-readable reports under .testing/coverage/. Only Source/
# production files contribute to the denominator.
coverage: image
	$(CONTAINER_RUNTIME) run --rm $(CONTAINER_MOUNTS) -w $(WORKDIR) $(IMAGE) \
		sh -c 'set -e; \
		  pgrep mosquitto >/dev/null 2>&1 || mosquitto -d; \
		  swift test --enable-code-coverage 2>/dev/null; \
		  BIN=$$(find .build -name AxolotyPackageTests.xctest -type f | head -1); \
		  PROFDATA=$$(find .build -name default.profdata | head -1); \
		  mkdir -p .testing/coverage; \
		  llvm-cov export "$$BIN" -instr-profile="$$PROFDATA" -format=text > .testing/coverage/coverage.json; \
		  python3 Tests/Support/coverage_ratchet.py summary .testing/coverage/coverage.json --report .testing/coverage/report.json'

# Compare the measured coverage against the committed baseline. Pure Python,
# so it runs on the host after `make coverage` produces the export.
coverage-check: coverage
	python3 Tests/Support/coverage_ratchet.py check .testing/coverage/coverage.json Tests/Support/coverage-baseline.json

# Keep these as dependency-only targets so one make invocation builds the
# container image once, even though every underlying target remains useful on
# its own. The explicit wire target also gives CI a stable compatibility gate.
ci-fast: build test-fast

ci: ci-fast test

broker: image
	@$(CONTAINER_RUNTIME) rm -f $(BROKER_NAME) >/dev/null 2>&1 || true
	$(CONTAINER_RUNTIME) run -d --name $(BROKER_NAME) -p 1883:1883 $(IMAGE) \
		mosquitto -c /etc/mosquitto/mosquitto.conf

broker-stop:
	$(CONTAINER_RUNTIME) rm -f $(BROKER_NAME)

shell: image
	$(CONTAINER_RUNTIME) run --rm -it $(CONTAINER_MOUNTS) -w $(WORKDIR) $(IMAGE) bash

docs: image
	$(CONTAINER_RUNTIME) run --rm $(CONTAINER_MOUNTS) -w $(WORKDIR) $(IMAGE) \
		swift package generate-documentation --target Axoloty \
			--transform-for-static-hosting \
			$(if $(DOC_HOSTING_BASE_PATH),--hosting-base-path $(DOC_HOSTING_BASE_PATH)) \
			--output-path .build/docc

clean:
	rm -rf "$(BUILD_DIR)"
