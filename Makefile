SHELL := /bin/sh

IMAGE ?= axoloty-dev
BROKER_NAME ?= coatyswift-mosquitto
CONTAINER_RUNTIME ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
WORKDIR := /workspace
CONTAINER_MOUNT_SUFFIX := $(if $(findstring podman,$(notdir $(CONTAINER_RUNTIME))),:Z,)
CACHE_NAMESPACE ?= swift-6.3-linux
# The sed delimiter must not be '#': GNU Make starts a comment at '#' even
# inside $(shell ...), which hides the closing paren and breaks parsing on
# GNU Make 3.81 (shipped by macOS). See issue #100.
REPOSITORY_NAME ?= $(shell git rev-parse --git-common-dir 2>/dev/null | sed 's|/.git$$||' | xargs basename 2>/dev/null || basename "$(CURDIR)")
BUILD_CACHE_ROOT ?= /tmp/coaty-swift-build/$(REPOSITORY_NAME)/$(CACHE_NAMESPACE)
WORKTREE_NAME ?= $(notdir $(CURDIR))
BUILD_DIR ?= $(BUILD_CACHE_ROOT)/worktrees/$(WORKTREE_NAME)/debug
COVERAGE_BUILD_DIR ?= $(BUILD_DIR)-coverage
TSAN_BUILD_DIR ?= $(BUILD_DIR)-tsan
BUILD_LOCK ?= 1
export BUILD_LOCK
ifeq ($(AXOLOTY_DEVCONTAINER),1)
SPM_CACHE_DIR ?= /workspace/.swiftpm-cache
else
SPM_CACHE_DIR ?= $(HOME)/.cache/coaty-swift/swiftpm/$(CACHE_NAMESPACE)
endif
CONTAINER_MOUNTS := -v "$(CURDIR):$(WORKDIR)$(CONTAINER_MOUNT_SUFFIX)" -v "$(BUILD_DIR):$(WORKDIR)/.build$(CONTAINER_MOUNT_SUFFIX)" -v "$(SPM_CACHE_DIR):$(WORKDIR)/.swiftpm-cache$(CONTAINER_MOUNT_SUFFIX)"
SWIFT_CACHE_ARGS := --cache-path /workspace/.swiftpm-cache
SWIFT_LOCKED_ARGS := $(SWIFT_CACHE_ARGS) --disable-automatic-resolution
COMMA := ,
AXOLOTY_TOOL_ARGS ?= --help
AXOLOTY_DEVICE ?= /dev/ttyACM0
AXOLOTY_TOOL_CONTAINER_OPTIONAL_DEVICES ?=
AXOLOTY_TOOL_CONTAINER_ENV_VARS ?=
SERVE_MQTT_ARGS ?=
SERVE_MCP_ARGS ?= --transport stdio
SERVE_DEV_ARGS ?=
export SERVE_MQTT_ARGS SERVE_MCP_ARGS SERVE_DEV_ARGS

.PHONY: serve-mqtt serve-mcp serve-dev

# Hosting base path for static DocC output. Set this to the repository name
# when publishing to a GitHub Pages project site (e.g. "axoloty" for
# https://<user>.github.io/axoloty/). Leave empty for root-hosted output.
DOC_HOSTING_BASE_PATH ?=

.PHONY: help image resolve coverage-resolve worktree-bootstrap worktree-warm axoloty-tool check hardware-check hardware-require release-snapshots checkpoint checkpoint-hardware test-tooling build wire-codec-test test-decoder-context-sendable test-no-anycodable test-no-foundation-types test-axoloty-wire-dependencies test-axoloty-wire-independent-resolution test test-tsan test-communication test-broker-regressions test-unit test-module test-fuzz fuzz-long test-fast test-wire test-wire-live test-wire-all test-support test-observation-linux coverage coverage-check ci-preflight ci-fast ci broker broker-stop shell docs lint wire-tool clean embedded-toolchain-doctor embedded-device-info embedded-device-smoke embedded-reproducible-build benchmark-size benchmark-wire benchmark-wire-bounds benchmark-wire-device check-budget-manifest check-embedded-swift check-embedded-swift-linker embedded-swift-build embedded-swift-flash embedded-swift-test embedded-mqtt-test embedded-network-test embedded-agent-test embedded-coatyjs-test embedded-host-test embedded-last-will-test embedded-broker-restart-test embedded-interop-test

help:
	@printf '%s\n' \
		'make image         Build the dev container image (includes ESP32-C6 toolchain)' \
		'make resolve       Resolve Package.resolved using the shared SwiftPM cache' \
		'make worktree-bootstrap  Prepare dependency cache and validate Package.resolved' \
		'make worktree-warm  Bootstrap and compile the current worktree' \
		'make axoloty-tool AXOLOTY_TOOL_ARGS="--help"  Run the Swift tooling CLI in-container' \
		'make check         Run the initial broker-free axoloty-tool check plan' \
		'make hardware-check  Run or skip the sporadic ESP32-C6 smoke check' \
		'make hardware-require  Require an attached ESP32-C6 smoke check' \
		'make release-snapshots  Generate and verify a provenance-rich wire bundle' \
		'make checkpoint     Run the 0.2 checkpoint validation (no hardware)' \
		'make checkpoint-hardware  Run checkpoint with ESP32-C6 smoke test' \
		'make test-tooling  Run the Swift tooling CLI tests' \
		'make build         Build Axoloty in the Linux container' \
		'make serve-mqtt    Run the local MQTT broker in the container' \
		'make serve-mcp     Run the MCP service in the container' \
		'make serve-dev     Run the MQTT + MCP development stack' \
		'make wire-codec-test  Run the Foundation-free wire codec unit tests' \
		'make test-communication  Run communication transport and subscription tests' \
		'make test-broker-regressions  Run broker-backed regression tests' \
		'make test-decoder-context-sendable  Fail if the former decoder-context Sendable diagnostic returns' \
		'make test-no-anycodable  Fail if AnyCodable is used in production source' \
		'make test-no-foundation-types  Fail if forbidden Foundation types are used in production source' \
		'make test          Run the full test suite (starts Mosquitto)' \
		'make test-tsan     Run broker-backed transport/lifecycle tests under Thread Sanitizer' \
		'make test-unit     Run ObjectMatcherTests' \
		'make test-module   Run targeted infrastructure module tests' \
		'make test-fuzz     Run deterministic property/fuzz tests' \
		'make fuzz-long     Run an auditable multi-seed fuzz campaign' \
		'make test-fast     Run unit, module, fuzz, offline wire, and support self-tests' \
		'make test-wire     Run offline wire fixtures and capture tests' \
		'make test-support  Run support harness self-tests and tier validation' \
		'make test-observation-linux  Run Observation and Broadcast tests on Linux' \
		'make coverage      Run tests with code coverage and report Source/ coverage' \
		'make coverage-check  Run coverage and fail if it regresses the baseline' \
		'make test-wire-live  Run live CoatyJS compatibility scenarios' \
		'make test-wire-all  Run offline and live compatibility suites' \
		'make wire-tool   Build the npx-runnable wire-compatibility CLI' \
		'make embedded-toolchain-doctor  Verify embedded tool versions and device access' \
		'make embedded-device-info  Query the board and record a device manifest' \
		'make embedded-device-smoke  Build, flash, and capture the smoke marker' \
		'make embedded-mqtt-test  Run the Swift MQTT overlay acceptance gate' \
		'make embedded-coatyjs-test  Run one Phase 4 direction (EMBEDDED_COATY_ROLE=A|B)' \
		'make embedded-host-test  Run one Phase 4 host direction (EMBEDDED_HOST_ROLE=A|B)' \
		'make embedded-last-will-test  Force-reset A and verify its broker-issued will on B' \
		'make embedded-broker-restart-test  Restart a broker and verify receive after resubscribe' \
		'make embedded-interop-test  Run the complete physical Phase 4 interoperability gate' \
		'make embedded-reproducible-build  Verify the firmware bin is reproducible' \
		'make benchmark-size  Build release consumers and compare binary-size baselines' \
		'make benchmark-wire  Run release wire benchmarks (p50/p95 latency + allocations)' \
		'make benchmark-wire-bounds  Run malformed-input and capacity bounds tests' \
		'make benchmark-wire-device  Run ESP32-C6 on-device wire benchmarks' \
		'make check-budget-manifest  Validate the performance budget manifest' \
		'make check-embedded-swift  Verify AxolotyWire compiles and links under Embedded Swift' \
		'make check-embedded-swift-linker  Verify Unicode runtime links for ESP32-C6' \
		'make embedded-swift-build  Build the ESP32-C6 Embedded Swift firmware' \
		'make embedded-swift-flash  Build, flash, and capture the Swift smoke marker' \
		'make embedded-swift-reproducible-build  Verify firmware is bit-for-bit reproducible' \
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
	$(CONTAINER_RUNTIME) build -t $(IMAGE) -f .devcontainer/Dockerfile .

resolve: image
	@mkdir -p "$(SPM_CACHE_DIR)"
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh .devcontainer/resolve.sh
	@git diff --exit-code -- Package.resolved

worktree-bootstrap: resolve
	@mkdir -p "$(BUILD_DIR)"

worktree-warm: worktree-bootstrap build

# Run axoloty-tool inside the container. The tool binary is prebuilt in the
# image at /opt/axoloty/bin/axoloty-tool. All commands execute in the
# container; no host extraction is needed.
axoloty-tool: image
	@AXOLOTY_HOST_RUNTIME_BRIDGE="$(AXOLOTY_HOST_RUNTIME_BRIDGE)" \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" \
	BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	AXOLOTY_DEVICE="$(AXOLOTY_DEVICE)" \
	CONTAINER_OPTIONAL_DEVICES="$(AXOLOTY_TOOL_CONTAINER_OPTIONAL_DEVICES)" \
	CONTAINER_ENV_VARS="$(AXOLOTY_TOOL_CONTAINER_ENV_VARS)" \
	.devcontainer/run.sh /opt/axoloty/bin/axoloty-tool $(AXOLOTY_TOOL_ARGS)

serve-mqtt: image
	@args="$$SERVE_MQTT_ARGS"; \
	case "$$args" in *[!-[:space:]0-9A-Za-z._/:=+,]*) echo "Invalid SERVE_MQTT_ARGS" >&2; exit 2;; esac; \
	set -f; set -- $$args; \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" CONTAINER_NETWORK=host .devcontainer/run.sh /opt/axoloty/bin/ax serve mqtt "$$@"

serve-mcp: image
	@args="$$SERVE_MCP_ARGS"; \
	case "$$args" in *[!-[:space:]0-9A-Za-z._/:=+,]*) echo "Invalid SERVE_MCP_ARGS" >&2; exit 2;; esac; \
	set -f; set -- $$args; \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" CONTAINER_NETWORK=host CONTAINER_STDIN=1 .devcontainer/run.sh /opt/axoloty/bin/ax serve mcp "$$@"

serve-dev: image
	@args="$$SERVE_DEV_ARGS"; \
	case "$$args" in *[!-[:space:]0-9A-Za-z._/:=+,]*) echo "Invalid SERVE_DEV_ARGS" >&2; exit 2;; esac; \
	set -f; set -- $$args; \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" CONTAINER_NETWORK=host .devcontainer/run.sh /opt/axoloty/bin/ax serve dev "$$@"

check:
	@$(MAKE) --no-print-directory axoloty-tool AXOLOTY_TOOL_ARGS=check

hardware-check:
	@$(MAKE) --no-print-directory axoloty-tool AXOLOTY_TOOL_ARGS='hardware check' \
		AXOLOTY_TOOL_CONTAINER_OPTIONAL_DEVICES='$(AXOLOTY_DEVICE)' AXOLOTY_TOOL_CONTAINER_ENV_VARS='AXOLOTY_DEVICE' \
		AXOLOTY_DEVICE='$(AXOLOTY_DEVICE)'

hardware-require:
	@$(MAKE) --no-print-directory axoloty-tool AXOLOTY_TOOL_ARGS='hardware require' \
		AXOLOTY_TOOL_CONTAINER_OPTIONAL_DEVICES='$(AXOLOTY_DEVICE)' AXOLOTY_TOOL_CONTAINER_ENV_VARS='AXOLOTY_DEVICE' \
		AXOLOTY_DEVICE='$(AXOLOTY_DEVICE)'

release-snapshots:
	@AXOLOTY_IMAGE_IDENTITY="$$( $(CONTAINER_RUNTIME) image inspect --format '{{.Id}}' "$(IMAGE)" )"; \
		AXOLOTY_GIT_COMMIT="$$(git rev-parse HEAD)"; \
		if test -z "$$(git status --porcelain)"; then AXOLOTY_GIT_CLEAN=true; else AXOLOTY_GIT_CLEAN=false; fi; \
		export AXOLOTY_IMAGE_IDENTITY AXOLOTY_GIT_COMMIT AXOLOTY_GIT_CLEAN; \
		$(MAKE) --no-print-directory axoloty-tool AXOLOTY_TOOL_ARGS='release snapshots' \
			AXOLOTY_TOOL_CONTAINER_ENV_VARS='AXOLOTY_IMAGE_IDENTITY AXOLOTY_GIT_COMMIT AXOLOTY_GIT_CLEAN' \
			AXOLOTY_IMAGE_IDENTITY="$$AXOLOTY_IMAGE_IDENTITY" AXOLOTY_GIT_COMMIT="$$AXOLOTY_GIT_COMMIT" \
			AXOLOTY_GIT_CLEAN="$$AXOLOTY_GIT_CLEAN"

checkpoint:
	@AXOLOTY_GIT_COMMIT="$$(git rev-parse --short HEAD)"; \
		if test -z "$$(git status --porcelain)"; then AXOLOTY_GIT_CLEAN=true; else AXOLOTY_GIT_CLEAN=false; fi; \
		export AXOLOTY_GIT_COMMIT AXOLOTY_GIT_CLEAN; \
		$(MAKE) --no-print-directory axoloty-tool AXOLOTY_TOOL_ARGS='release checkpoint' \
			AXOLOTY_TOOL_CONTAINER_ENV_VARS='AXOLOTY_GIT_COMMIT AXOLOTY_GIT_CLEAN' \
			AXOLOTY_GIT_COMMIT="$$AXOLOTY_GIT_COMMIT" AXOLOTY_GIT_CLEAN="$$AXOLOTY_GIT_CLEAN"

checkpoint-hardware:
	@AXOLOTY_GIT_COMMIT="$$(git rev-parse --short HEAD)"; \
		if test -z "$$(git status --porcelain)"; then AXOLOTY_GIT_CLEAN=true; else AXOLOTY_GIT_CLEAN=false; fi; \
		export AXOLOTY_GIT_COMMIT AXOLOTY_GIT_CLEAN; \
		$(MAKE) --no-print-directory axoloty-tool AXOLOTY_TOOL_ARGS='release checkpoint-hardware' \
			AXOLOTY_TOOL_CONTAINER_OPTIONAL_DEVICES="$${AXOLOTY_DEVICE:-/dev/ttyACM0}" \
			AXOLOTY_TOOL_CONTAINER_ENV_VARS='AXOLOTY_GIT_COMMIT AXOLOTY_GIT_CLEAN AXOLOTY_DEVICE' \
			AXOLOTY_GIT_COMMIT="$$AXOLOTY_GIT_COMMIT" AXOLOTY_GIT_CLEAN="$$AXOLOTY_GIT_CLEAN" \
			AXOLOTY_DEVICE="$${AXOLOTY_DEVICE:-/dev/ttyACM0}"

test-tooling: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift test $(SWIFT_LOCKED_ARGS) --filter AxolotyToolingTests

test-communication: image
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh \
		swift test $(SWIFT_LOCKED_ARGS) --filter 'CommunicationSubscriptionCoordinatorTests|BroadcastTransportTests|MQTTNIOClientTests'

test-broker-regressions: image
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh \
		sh -c 'pgrep mosquitto >/dev/null 2>&1 || mosquitto -d; swift test $(SWIFT_LOCKED_ARGS) --filter "DecentralizedLoggingTest|ObjectLifecycleControllerTests"'

build:
	@$(MAKE) --no-print-directory axoloty-tool AXOLOTY_TOOL_ARGS=build

wire-codec-test: build
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh \
		swift test $(SWIFT_LOCKED_ARGS) --filter 'WireCodecTests|StaticDispatchTests|WireDifferentialTests|MessageRouterTests|BorrowedMessageTests'

test-decoder-context-sendable:
	@build_log=$$(mktemp); \
	trap 'rm -f "$$build_log"' EXIT; \
	if ! $(MAKE) build >"$$build_log" 2>&1; then cat "$$build_log"; exit 1; fi; \
	cat "$$build_log"; \
	sh Tests/Support/check-decoder-context-diagnostic.sh "$$build_log"

test-no-anycodable:
	@sh Tests/Support/check-no-anycodable.sh

test-no-foundation-types:
	@sh Tests/Support/check-no-foundation-types.sh

test-axoloty-wire-dependencies:
	@sh Tests/Support/check-axoloty-wire-dependencies.sh Packages/AxolotyWire

test-axoloty-wire-independent-resolution:
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh sh Tests/Support/check-axoloty-wire-independent-resolution.sh

test: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh sh -c 'pgrep mosquitto >/dev/null 2>&1 || mosquitto -d; AXOLOTY_INSPECTOR_LIVE=1 swift test $(SWIFT_LOCKED_ARGS)'

tsan-resolve: image
	@mkdir -p "$(SPM_CACHE_DIR)"
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(TSAN_BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh .devcontainer/resolve.sh
	@git diff --exit-code -- Package.resolved

test-tsan: tsan-resolve
	CONTAINER_SECURITY_OPTS="--security-opt seccomp=unconfined" \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(TSAN_BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh \
		bash -o pipefail -c 'set -e; pgrep mosquitto >/dev/null 2>&1 || mosquitto -d; swift test $(SWIFT_LOCKED_ARGS) --no-parallel --sanitize=thread --filter "CommunicationSubscriptionCoordinatorTests|BroadcastTransportTests|ObjectLifecycleControllerTests|DecentralizedLoggingTest"'

test-unit: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift test $(SWIFT_LOCKED_ARGS) --filter 'ObjectMatcherTests|CoatyUUIDTests'

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

test-wire:
	@$(MAKE) --no-print-directory axoloty-tool AXOLOTY_TOOL_ARGS='wire verify'

# Harness self-tests intentionally remain host-side Shell/JavaScript checks.
test-support:
	Tests/Support/test-check-axoloty-wire-dependencies.sh
	Tests/Support/test-check-axoloty-wire-independent-resolution.sh
	Tests/Support/test-check-axoloty-wire-test-isolation.sh
	Tests/Support/test-check-benchmark-corpus.sh
	Tests/Support/test-embedded-swift-smoke.sh
	Tests/Support/test-embedded-swift-test.sh
	Tests/Support/test-embedded-network.sh
	Tests/Support/test-embedded-mqtt-client.sh
	Tests/Support/test-embedded-coatyjs.sh
	Tests/Support/test-run-container.sh
	Tests/Fuzzing/test-run-fuzz.sh
	cd Tests/WireCompatibility/tool && npm ci && npm test
	node --test Tests/Support/*.test.mjs
	node Tests/Support/validate-test-tiers.mjs Tests/Support/test-tiers.json

test-wire-live:
	@$(MAKE) --no-print-directory axoloty-tool AXOLOTY_TOOL_ARGS='wire capture' AXOLOTY_HOST_RUNTIME_BRIDGE=1

test-wire-all: test-wire test-wire-live

wire-tool:
	cd Tests/WireCompatibility/tool && npm ci && npm test

# ESP32-C6 embedded toolchain is included in the single dev image.
# See .devcontainer/Dockerfile and docs/embedded-toolchain.md.

embedded-toolchain-doctor:
	CONTAINER_DEVICES=/dev/ttyACM0 \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" \
	BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/check-embedded-toolchain.sh

embedded-device-info:
	CONTAINER_DEVICES=/dev/ttyACM0 \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" \
	BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/embedded-device-info.sh

embedded-device-smoke:
	CONTAINER_DEVICES=/dev/ttyACM0 \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" \
	BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/embedded-device-smoke.sh

embedded-reproducible-build:
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" \
	BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/embedded-reproducible-build.sh

embedded-swift-build:
	@$(MAKE) --no-print-directory axoloty-tool AXOLOTY_TOOL_ARGS='embedded build'

embedded-swift-flash: embedded-swift-build
	@CONTAINER_DEVICES=/dev/ttyACM0 \
	CONTAINER_RECLAIM_BUILD_DIR=1 EMBEDDED_SKIP_BUILD=1 \
	EMBEDDED_BUILD_DIR=/workspace/.build/embedded-swift \
	EMBEDDED_OUTPUT_DIR=/workspace/.build/embedded-results \
	CONTAINER_ENV_VARS="EMBEDDED_SKIP_BUILD EMBEDDED_BUILD_DIR EMBEDDED_OUTPUT_DIR" \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" \
	BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/embedded-swift-smoke.sh; \
	status=$$?; \
	mkdir -p .testing/embedded || exit 1; \
	for artifact in swift-smoke-log.txt swift-smoke-result.json; do \
		if [ -f "$(BUILD_DIR)/embedded-results/$$artifact" ]; then \
			cp "$(BUILD_DIR)/embedded-results/$$artifact" .testing/embedded/ || exit 1; \
		fi; \
	done; \
	exit $$status

embedded-swift-test: embedded-swift-build
	@CONTAINER_DEVICES=/dev/ttyACM0 CONTAINER_RECLAIM_BUILD_DIR=1 EMBEDDED_SKIP_BUILD=1 \
	EMBEDDED_BUILD_DIR=/workspace/.build/embedded-swift EMBEDDED_OUTPUT_DIR=/workspace/.build/embedded-results \
	EMBEDDED_VALIDATOR=/workspace/Tests/Support/embedded-swift-test-validator.mjs \
	CONTAINER_ENV_VARS="EMBEDDED_SKIP_BUILD EMBEDDED_BUILD_DIR EMBEDDED_OUTPUT_DIR EMBEDDED_VALIDATOR EMBEDDED_VALIDATOR_FACTORY" \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/embedded-swift-test.sh; \
	status=$$?; \
	mkdir -p .testing/embedded || exit 1; \
	for artifact in swift-smoke-log.txt swift-smoke-result.json; do \
		if [ -f "$(BUILD_DIR)/embedded-results/$$artifact" ]; then \
			cp "$(BUILD_DIR)/embedded-results/$$artifact" ".testing/embedded/vector-$$artifact" || exit 1; \
		fi; \
	done; \
	exit $$status

embedded-network-test:
	@test -n "$$AXOLOTY_WIFI_SSID" && test -n "$$AXOLOTY_WIFI_PASSWORD" || { echo 'embedded network test requires AXOLOTY_WIFI_SSID and AXOLOTY_WIFI_PASSWORD' >&2; exit 2; }
	@CONTAINER_DEVICES="$${EMBEDDED_DEVICE:-/dev/ttyACM0}" CONTAINER_RECLAIM_BUILD_DIR=1 \
	EMBEDDED_BUILD_DIR=/workspace/.build/embedded-swift-network EMBEDDED_OUTPUT_DIR=/workspace/.build/embedded-network-results \
	CONTAINER_ENV_VARS="AXOLOTY_WIFI_SSID AXOLOTY_WIFI_PASSWORD AXOLOTY_MQTT_HOST AXOLOTY_MQTT_PORT EMBEDDED_DEVICE EMBEDDED_BUILD_DIR EMBEDDED_OUTPUT_DIR" \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/embedded-network-test.sh

embedded-mqtt-test: embedded-network-test

embedded-agent-test:
	@test -n "$$AXOLOTY_WIFI_SSID" && test -n "$$AXOLOTY_WIFI_PASSWORD" || { echo 'embedded agent test requires AXOLOTY_WIFI_SSID and AXOLOTY_WIFI_PASSWORD' >&2; exit 2; }
	@CONTAINER_DEVICES="$${EMBEDDED_DEVICE_A:-/dev/ttyACM0} $${EMBEDDED_DEVICE_B:-/dev/ttyACM1}" CONTAINER_RECLAIM_BUILD_DIR=1 \
	CONTAINER_ENV_VARS="AXOLOTY_WIFI_SSID AXOLOTY_WIFI_PASSWORD AXOLOTY_MQTT_HOST AXOLOTY_MQTT_PORT EMBEDDED_DEVICE_A EMBEDDED_DEVICE_B EMBEDDED_AGENT_BUILD_ROOT EMBEDDED_OUTPUT_DIR EMBEDDED_AGENT_BUILD_ONLY" \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/embedded-agent-test.sh

embedded-coatyjs-test:
	@test -n "$$AXOLOTY_WIFI_SSID" && test -n "$$AXOLOTY_WIFI_PASSWORD" && test -n "$$AXOLOTY_MQTT_HOST" || { echo 'embedded CoatyJS test requires Wi-Fi and broker settings' >&2; exit 2; }
	@CONTAINER_DEVICES="$${EMBEDDED_DEVICE:-/dev/ttyACM0}" CONTAINER_RECLAIM_BUILD_DIR=1 \
	CONTAINER_ENV_VARS="AXOLOTY_WIFI_SSID AXOLOTY_WIFI_PASSWORD AXOLOTY_MQTT_HOST AXOLOTY_MQTT_PORT EMBEDDED_COATY_ROLE EMBEDDED_DEVICE EMBEDDED_COATY_BUILD_ROOT EMBEDDED_OUTPUT_DIR EMBEDDED_COATY_DEADLINE" \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/embedded-coatyjs-test.sh

embedded-host-test:
	@test -n "$$AXOLOTY_WIFI_SSID" && test -n "$$AXOLOTY_WIFI_PASSWORD" && test -n "$$AXOLOTY_MQTT_HOST" || { echo 'embedded host test requires Wi-Fi and broker settings' >&2; exit 2; }
	@CONTAINER_DEVICES="$${EMBEDDED_DEVICE:-/dev/ttyACM0}" CONTAINER_RECLAIM_BUILD_DIR=1 \
	CONTAINER_ENV_VARS="AXOLOTY_WIFI_SSID AXOLOTY_WIFI_PASSWORD AXOLOTY_MQTT_HOST AXOLOTY_MQTT_PORT EMBEDDED_HOST_ROLE EMBEDDED_DEVICE EMBEDDED_HOST_BUILD_ROOT EMBEDDED_HOST_SWIFT_BUILD EMBEDDED_OUTPUT_DIR EMBEDDED_HOST_DEADLINE EMBEDDED_HOST_BUILD_DEADLINE" \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/embedded-host-test.sh

embedded-last-will-test:
	@test -n "$$AXOLOTY_WIFI_SSID" && test -n "$$AXOLOTY_WIFI_PASSWORD" && test -n "$$AXOLOTY_MQTT_HOST" || { echo 'embedded last-will test requires Wi-Fi and broker settings' >&2; exit 2; }
	@CONTAINER_DEVICES="$${EMBEDDED_DEVICE_A:-/dev/ttyACM0} $${EMBEDDED_DEVICE_B:-/dev/ttyACM1}" CONTAINER_RECLAIM_BUILD_DIR=1 \
	CONTAINER_ENV_VARS="AXOLOTY_WIFI_SSID AXOLOTY_WIFI_PASSWORD AXOLOTY_MQTT_HOST AXOLOTY_MQTT_PORT EMBEDDED_DEVICE_A EMBEDDED_DEVICE_B EMBEDDED_LAST_WILL_BUILD_ROOT EMBEDDED_OUTPUT_DIR EMBEDDED_LAST_WILL_DEADLINE" \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/embedded-last-will-test.sh

embedded-broker-restart-test:
	@test -n "$$AXOLOTY_WIFI_SSID" && test -n "$$AXOLOTY_WIFI_PASSWORD" && test -n "$$AXOLOTY_MQTT_HOST" || { echo 'embedded broker-restart test requires Wi-Fi and broker host settings' >&2; exit 2; }
	@CONTAINER_DEVICES="$${EMBEDDED_DEVICE:-/dev/ttyACM1}" CONTAINER_RECLAIM_BUILD_DIR=1 \
	CONTAINER_SECURITY_OPTS="--network host" \
	CONTAINER_ENV_VARS="AXOLOTY_WIFI_SSID AXOLOTY_WIFI_PASSWORD AXOLOTY_MQTT_HOST EMBEDDED_BROKER_RESTART_PORT EMBEDDED_BROKER_RESTART_MANAGED EMBEDDED_DEVICE EMBEDDED_BROKER_RESTART_BUILD_DIR EMBEDDED_OUTPUT_DIR EMBEDDED_BROKER_RESTART_DEADLINE" \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/embedded-broker-restart-test.sh

embedded-interop-test:
	@status=0; \
	$(MAKE) --no-print-directory embedded-agent-test || status=1; \
	$(MAKE) --no-print-directory embedded-host-test EMBEDDED_HOST_ROLE=A EMBEDDED_DEVICE="$${EMBEDDED_DEVICE_A:-/dev/ttyACM0}" || status=1; \
	$(MAKE) --no-print-directory embedded-host-test EMBEDDED_HOST_ROLE=B EMBEDDED_DEVICE="$${EMBEDDED_DEVICE_B:-/dev/ttyACM1}" || status=1; \
	$(MAKE) --no-print-directory embedded-coatyjs-test EMBEDDED_COATY_ROLE=A EMBEDDED_DEVICE="$${EMBEDDED_DEVICE_A:-/dev/ttyACM0}" || status=1; \
	$(MAKE) --no-print-directory embedded-coatyjs-test EMBEDDED_COATY_ROLE=B EMBEDDED_DEVICE="$${EMBEDDED_DEVICE_B:-/dev/ttyACM1}" || status=1; \
	$(MAKE) --no-print-directory embedded-last-will-test || status=1; \
	$(MAKE) --no-print-directory embedded-broker-restart-test EMBEDDED_DEVICE="$${EMBEDDED_DEVICE_B:-/dev/ttyACM1}" || status=1; \
	exit $$status

check-embedded-swift-linker:
	@$(MAKE) --no-print-directory axoloty-tool AXOLOTY_TOOL_ARGS='embedded verify'

embedded-swift-reproducible-build:
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" \
	BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/embedded-swift-reproducible-build.sh

test-observation-linux: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift test $(SWIFT_LOCKED_ARGS) --filter "ObservationLinuxTests|BroadcastTests"

test-fast: test-unit test-module test-fuzz test-wire test-support test-axoloty-wire-dependencies test-axoloty-wire-independent-resolution

coverage-resolve: image
	@mkdir -p "$(SPM_CACHE_DIR)"
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(COVERAGE_BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh .devcontainer/resolve.sh
	@git diff --exit-code -- Package.resolved

coverage: coverage-resolve
	@mkdir -p .testing/coverage
	@if [ -n "$(COVERAGE_DIFF_BASE)" ]; then git diff --unified=0 "$(COVERAGE_DIFF_BASE)" HEAD > .testing/coverage/changed.diff; else git diff --unified=0 HEAD^ HEAD > .testing/coverage/changed.diff; fi
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(COVERAGE_BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh \
		bash -o pipefail -c 'set -e; \
		  pgrep mosquitto >/dev/null 2>&1 || mosquitto -d; \
		  # Several integration tests configure process-global runtime settings, including LogManager.defaultLevel. \
		  # Swift Testing otherwise runs unrelated suites concurrently, which makes their setup race. \
		  swift test $(SWIFT_LOCKED_ARGS) --no-parallel --enable-code-coverage 2>&1 | tee .testing/coverage/build.log; \
		  BIN=$$(find .build -name AxolotyPackageTests.xctest -type f | head -1); \
		  PROFDATA=$$(find .build -name default.profdata | head -1); \
		  mkdir -p .testing/coverage; \
		  llvm-cov export "$$BIN" -instr-profile="$$PROFDATA" -format=text > .testing/coverage/coverage.json; \
		  node Tests/Support/coverage-tools.mjs summary .testing/coverage/coverage.json --report .testing/coverage/report.json; \
		  node Tests/Support/coverage-tools.mjs report .testing/coverage/coverage.json .testing/coverage/changed.diff'

coverage-check: coverage
	node Tests/Support/coverage-tools.mjs check .testing/coverage/coverage.json Tests/Support/coverage-baseline.json

ci-fast: build test-fast

ci-preflight:
	@if [ "$${CI:-}" = "true" ] && [ "$(BUILD_LOCK)" != "0" ]; then echo 'CI must set BUILD_LOCK=0 because its workspace-local build directory is not shared' >&2; exit 2; fi

ci: ci-preflight test-no-anycodable test-no-foundation-types test-axoloty-wire-dependencies test-axoloty-wire-independent-resolution
	$(MAKE) test-support coverage-check
	sh Tests/Support/check-decoder-context-diagnostic.sh .testing/coverage/build.log

broker: image
	@printf '%s\n' 'warning: make broker is deprecated; use make serve-mqtt' >&2
	@$(CONTAINER_RUNTIME) rm -f $(BROKER_NAME) >/dev/null 2>&1 || true
	$(CONTAINER_RUNTIME) run -d --name $(BROKER_NAME) -p 1883:1883 $(IMAGE) \
		mosquitto -c /etc/mosquitto/conf.d/coatyswift.conf

broker-stop:
	@printf '%s\n' 'warning: make broker-stop is deprecated; use Ctrl-C on make serve-mqtt' >&2
	$(CONTAINER_RUNTIME) rm -f $(BROKER_NAME)

shell: image
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh bash

docs: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh swift package $(SWIFT_LOCKED_ARGS) generate-documentation --target Axoloty \
		--disable-indexing \
		--transform-for-static-hosting \
		$(if $(DOC_HOSTING_BASE_PATH),--hosting-base-path $(DOC_HOSTING_BASE_PATH)) \
		--output-path .build/docc
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh sh .github/scripts/write-docs-root-redirect.sh .build/docc
	@echo "docs: mirroring .build/docc -> .build-output/docc (repo-local, survives reboot)"
	@CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh sh -c 'rm -rf .build-output/docc && mkdir -p .build-output && cp -R .build/docc .build-output/docc'

lint: image
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" .devcontainer/run.sh swiftlint lint --no-cache --config .swiftlint.yml

benchmark-size: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" \
	BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/check-benchmark-size.sh

benchmark-wire: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" \
	BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/check-benchmark-wire.sh

benchmark-wire-bounds: resolve
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" \
	BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/check-benchmark-wire-bounds.sh

benchmark-wire-device: resolve
	CONTAINER_DEVICES=/dev/ttyACM0 \
	CONTAINER_RECLAIM_BUILD_DIR=1 \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" \
	BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/check-benchmark-wire-device.sh

check-budget-manifest:
	Tests/Support/check-budget-manifest.sh

check-embedded-swift:
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" \
	BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	.devcontainer/run.sh /workspace/Tests/Support/check-embedded-swift.sh

clean:
	rm -rf "$(BUILD_DIR)" "$(COVERAGE_BUILD_DIR)"
