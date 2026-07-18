SHELL := /bin/sh

IMAGE ?= coatyswift-dev
BROKER_NAME ?= coatyswift-mosquitto
CONTAINER_RUNTIME ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
WORKDIR := /workspace
CACHE_NAMESPACE ?= swift-6.3-linux
# The sed delimiter must not be '#': GNU Make starts a comment at '#' even
# inside $(shell ...), which hides the closing paren and breaks parsing on
# GNU Make 3.81 (shipped by macOS). See issue #100.
REPOSITORY_NAME ?= $(shell git rev-parse --git-common-dir 2>/dev/null | sed 's|/.git$$||' | xargs basename 2>/dev/null || basename "$(CURDIR)")
BUILD_CACHE_ROOT ?= /tmp/coaty-swift-build/$(REPOSITORY_NAME)/$(CACHE_NAMESPACE)
BUILD_DIR ?= $(BUILD_CACHE_ROOT)/debug
COVERAGE_BUILD_DIR ?= $(BUILD_DIR)-coverage
BUILD_LOCK ?= 1
export BUILD_LOCK
ifeq ($(AXOLOTY_DEVCONTAINER),1)
SPM_CACHE_DIR ?= /workspace/.swiftpm-cache
else
SPM_CACHE_DIR ?= $(HOME)/.cache/coaty-swift/swiftpm/$(CACHE_NAMESPACE)
endif
CONTAINER_MOUNTS := -v "$(CURDIR):$(WORKDIR)" -v "$(BUILD_DIR):$(WORKDIR)/.build" -v "$(SPM_CACHE_DIR):$(WORKDIR)/.swiftpm-cache"
SWIFT_CACHE_ARGS := --cache-path /workspace/.swiftpm-cache
SWIFT_LOCKED_ARGS := $(SWIFT_CACHE_ARGS) --disable-automatic-resolution
COMMA := ,

# Hosting base path for static DocC output. Set this to the repository name
# when publishing to a GitHub Pages project site (e.g. "axoloty" for
# https://<user>.github.io/axoloty/). Leave empty for root-hosted output.
DOC_HOSTING_BASE_PATH ?=

.PHONY: help image resolve coverage-resolve worktree-bootstrap worktree-warm build test-decoder-context-sendable test test-communication test-broker-regressions test-unit test-module test-fuzz fuzz-long test-fast test-wire test-wire-live test-wire-all test-support test-observation-linux coverage coverage-check ci-preflight ci-fast ci broker broker-stop shell docs clean

help:
	@printf '%s\n' \
		'make image         Build the Linux Swift development image' \
		'make resolve       Resolve Package.resolved using the shared SwiftPM cache' \
		'make worktree-bootstrap  Prepare dependency cache and validate Package.resolved' \
		'make worktree-warm  Bootstrap and compile the current worktree' \
		'make build         Build Axoloty in the Linux container' \
		'make test-decoder-context-sendable  Fail if the former decoder-context Sendable diagnostic returns' \
		'make test          Run the full test suite (starts Mosquitto)' \
		'make test-unit     Run ObjectMatcherTests' \
		'make test-module   Run targeted infrastructure module tests' \
		'make test-fuzz     Run deterministic property/fuzz tests' \
		'make fuzz-long     Run an auditable multi-seed fuzz campaign' \
		'make test-fast     Run unit, module, fuzz, offline wire, and support self-tests' \
		'make test-wire     Run offline wire fixtures and capture tests' \
		'make test-support  Run Python/shell harness self-tests and tier validation' \
		'make test-observation-linux  Run Observation and EventStream tests on Linux' \
		'make coverage      Run tests with code coverage and report Source/ coverage' \
		'make coverage-check  Run coverage and fail if it regresses the baseline' \
		'make test-wire-live  Run live CoatyJS compatibility scenarios' \
		'make test-wire-all  Run offline and live compatibility suites' \
		'make ci-fast       Run the build and fast test suite' \
		'make ci            Run the consolidated pull-request checks' \
		'make broker        Start Mosquitto on localhost:1883' \
		'make broker-stop   Stop the background Mosquitto container' \
		'make shell         Open a shell in the Linux container' \
		'make docs          Generate DocC API documentation into the active build cache' \
		'make clean         Remove normal and coverage build artifacts' \
		'' \
		'BUILD_DIR and SPM_CACHE_DIR can point at different local cache directories' \
		'BUILD_DIR defaults to a shared cache under /tmp; BUILD_LOCK=0 disables waiting for isolated CI runs' \
		'COVERAGE_BUILD_DIR isolates instrumented artifacts from normal builds'

image:
	@if [ "$(AXOLOTY_DEVCONTAINER)" = "1" ]; then exit 0; fi
	@test -n "$(CONTAINER_RUNTIME)" || (echo 'No podman or docker runtime found' >&2; exit 1)
	@mkdir -p "$(BUILD_DIR)" "$(SPM_CACHE_DIR)"
	$(CONTAINER_RUNTIME) build -t $(IMAGE) -f .devcontainer/Dockerfile .devcontainer

resolve: image
	@mkdir -p "$(SPM_CACHE_DIR)"
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh .devcontainer/resolve.sh
	@git diff --exit-code -- Package.resolved

worktree-bootstrap: resolve
	@mkdir -p "$(BUILD_DIR)"

worktree-warm: worktree-bootstrap build

test-communication: image
	$(CONTAINER_RUNTIME) run --rm $(CONTAINER_MOUNTS) -w $(WORKDIR) $(IMAGE) \
		swift test $(SWIFT_LOCKED_ARGS) --filter 'CommunicationSubscriptionCoordinatorTests|EventHubTransportTests'

test-broker-regressions: image
	$(CONTAINER_RUNTIME) run --rm $(CONTAINER_MOUNTS) -w $(WORKDIR) $(IMAGE) \
		sh -c 'pgrep mosquitto >/dev/null 2>&1 || mosquitto -d; swift test $(SWIFT_LOCKED_ARGS) --filter "DecentralizedLoggingTest|ObjectLifecycleControllerTests"'

build: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift build $(SWIFT_LOCKED_ARGS)

test-decoder-context-sendable:
	@build_log=$$(mktemp); \
	trap 'rm -f "$$build_log"' EXIT; \
	if ! $(MAKE) build >"$$build_log" 2>&1; then cat "$$build_log"; exit 1; fi; \
	cat "$$build_log"; \
	sh Tests/Support/check-decoder-context-diagnostic.sh "$$build_log"

test: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh sh -c 'pgrep mosquitto >/dev/null 2>&1 || mosquitto -d; swift test $(SWIFT_LOCKED_ARGS)'

test-unit: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift test $(SWIFT_LOCKED_ARGS) --filter ObjectMatcherTests

test-module: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift test $(SWIFT_LOCKED_ARGS) --filter CommunicationTopicTests
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift test $(SWIFT_LOCKED_ARGS) --filter PayloadCoderTests
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift test $(SWIFT_LOCKED_ARGS) --filter ObjectTypeRegistryTests
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift test $(SWIFT_LOCKED_ARGS) --filter ConfigurationBuilderTests

test-fuzz: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh \
		sh -c 'AXOLOTY_FUZZ_ITERATIONS="$(or $(AXOLOTY_FUZZ_ITERATIONS),250)" AXOLOTY_FUZZ_SEED="$(or $(AXOLOTY_FUZZ_SEED),0x41584f4c4f5459)" swift test $(SWIFT_LOCKED_ARGS) --filter DeterministicFuzzTests'

fuzz-long:
	AXOLOTY_FUZZ_ITERATIONS="$(or $(AXOLOTY_FUZZ_ITERATIONS),100000)" \
	AXOLOTY_FUZZ_SEEDS="$(if $(AXOLOTY_FUZZ_SEEDS),$(AXOLOTY_FUZZ_SEEDS),1$(COMMA)2$(COMMA)3$(COMMA)4)" \
	AXOLOTY_FUZZ_REPETITIONS="$(or $(AXOLOTY_FUZZ_REPETITIONS),1)" \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" \
		Tests/Fuzzing/run-fuzz.sh

test-wire: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift test $(SWIFT_LOCKED_ARGS) --filter WireFixtureTests
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift test $(SWIFT_LOCKED_ARGS) --filter LegacyCaptureFixtureTests
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift test $(SWIFT_LOCKED_ARGS) --filter LifecycleCompatibilityScenarioTests
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift test $(SWIFT_LOCKED_ARGS) --filter AxolotyIoAssociateTests
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift test $(SWIFT_LOCKED_ARGS) --filter AxolotyIoNegativeTests

# Harness self-tests intentionally remain host-side Python/shell checks.
test-support:
	Tests/Support/test-run-container.sh
	Tests/Fuzzing/test-run-fuzz.sh
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/WireCompatibility/Capture -p 'test_*.py' -v
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/WireCompatibility/Legacy -p 'test_*.py' -v
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/WireCompatibility/Live -p 'test_*.py' -v
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/WireCompatibility/IO/Live -p 'test_*.py' -v
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/WireCompatibility/Lifecycle/Live -p 'test_*.py' -v
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/WireCompatibility/Reverse -p 'test_*.py' -v
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Support -p 'test_*.py' -v
	python3 Tests/Support/validate_test_tiers.py Tests/Support/test-tiers.json

test-wire-live:
	CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) Tests/WireCompatibility/Live/run-coatyjs-advertise.sh
	CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) Tests/WireCompatibility/Live/run-coatyjs-core.sh
	CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) Tests/WireCompatibility/Lifecycle/Live/run-lifecycle-matrix.sh
	CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) Tests/WireCompatibility/Reverse/run-axoloty-advertise.sh
	CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) Tests/WireCompatibility/Reverse/run-axoloty-core.sh
	CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) Tests/WireCompatibility/Reverse/run-coatyjs-to-axoloty-advertise.sh
	CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) Tests/WireCompatibility/IO/Live/run-io-associate.sh

test-wire-all: test-wire test-wire-live

test-observation-linux: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift test $(SWIFT_LOCKED_ARGS) --filter "ObservationLinuxTests|EventStreamTests"

test-fast: test-unit test-module test-fuzz test-wire test-support

coverage-resolve: image
	@mkdir -p "$(SPM_CACHE_DIR)"
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(COVERAGE_BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh .devcontainer/resolve.sh
	@git diff --exit-code -- Package.resolved

coverage: coverage-resolve
	@mkdir -p .testing/coverage
	@if [ -n "$(COVERAGE_DIFF_BASE)" ]; then git diff --unified=0 "$(COVERAGE_DIFF_BASE)" HEAD > .testing/coverage/changed.diff; else git diff --unified=0 HEAD^ HEAD > .testing/coverage/changed.diff; fi
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(COVERAGE_BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh \
		sh -c 'set -e; \
		  pgrep mosquitto >/dev/null 2>&1 || mosquitto -d; \
		  # Several integration tests configure process-global runtime settings, including LogManager.defaultLevel. \
		  # Swift Testing otherwise runs unrelated suites concurrently, which makes their setup race. \
		  swift test $(SWIFT_LOCKED_ARGS) --no-parallel --enable-code-coverage; \
		  BIN=$$(find .build -name AxolotyPackageTests.xctest -type f | head -1); \
		  PROFDATA=$$(find .build -name default.profdata | head -1); \
		  mkdir -p .testing/coverage; \
		  llvm-cov export "$$BIN" -instr-profile="$$PROFDATA" -format=text > .testing/coverage/coverage.json; \
		  PYTHONDONTWRITEBYTECODE=1 python3 Tests/Support/coverage_ratchet.py summary .testing/coverage/coverage.json --report .testing/coverage/report.json; \
		  PYTHONDONTWRITEBYTECODE=1 python3 Tests/Support/coverage_report.py .testing/coverage/coverage.json .testing/coverage/changed.diff'

coverage-check: coverage
	python3 Tests/Support/coverage_ratchet.py check .testing/coverage/coverage.json Tests/Support/coverage-baseline.json

ci-fast: build test-fast

ci-preflight:
	@if [ "$${CI:-}" = "true" ] && [ "$(BUILD_LOCK)" != "0" ]; then echo 'CI must set BUILD_LOCK=0 because its workspace-local build directory is not shared' >&2; exit 2; fi

ci: ci-preflight test-decoder-context-sendable
	$(MAKE) test-support coverage-check

broker: image
	@$(CONTAINER_RUNTIME) rm -f $(BROKER_NAME) >/dev/null 2>&1 || true
	$(CONTAINER_RUNTIME) run -d --name $(BROKER_NAME) -p 1883:1883 $(IMAGE) \
		mosquitto -c /etc/mosquitto/mosquitto.conf

broker-stop:
	$(CONTAINER_RUNTIME) rm -f $(BROKER_NAME)

shell: image
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh bash

docs: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift package $(SWIFT_LOCKED_ARGS) generate-documentation --target Axoloty \
		--disable-indexing \
		--transform-for-static-hosting \
		$(if $(DOC_HOSTING_BASE_PATH),--hosting-base-path $(DOC_HOSTING_BASE_PATH)) \
		--output-path .build/docc

clean:
	rm -rf "$(BUILD_DIR)" "$(COVERAGE_BUILD_DIR)"
