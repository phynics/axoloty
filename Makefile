SHELL := /bin/sh

IMAGE ?= axoloty-dev
BROKER_NAME ?= coatyswift-mosquitto
CONTAINER_RUNTIME ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
WORKDIR := /workspace
# SELinux relabeling is opt-in for unusual hosts; run.sh detects active
# labeling for ordinary Podman invocations and honors this override.
CONTAINER_MOUNT_SUFFIX ?=
export CONTAINER_MOUNT_SUFFIX
CACHE_NAMESPACE ?= swift-6.3-linux
# The sed delimiter must not be '#': GNU Make starts a comment at '#' even
# inside $(shell ...), which hides the closing paren and breaks parsing on
# GNU Make 3.81 (shipped by macOS). See issue #100.
REPOSITORY_NAME ?= $(shell git rev-parse --git-common-dir 2>/dev/null | sed 's|/.git$$||' | xargs basename 2>/dev/null || basename "$(CURDIR)")
BUILD_CACHE_ROOT ?= /tmp/coaty-swift-build/$(REPOSITORY_NAME)/$(CACHE_NAMESPACE)
WORKTREE_NAME ?= $(notdir $(CURDIR))
# Every top-level make invocation owns a distinct mutable-output namespace.
# AXOLOTY_RUN_ID is inherited by recursive make calls and may be supplied by
# CI when a workflow needs a stable, externally named run.
RUN_ID ?= $(AXOLOTY_RUN_ID)
ifeq ($(strip $(RUN_ID)),)
RUN_ID := $(shell printf '%s-%s' "$$(date +%s)" "$$$$")
endif
AXOLOTY_RUN_ID ?= $(RUN_ID)
AXOLOTY_RUNS_DIR ?= .testing/runs
WIRE_OUTPUT_DIR ?= $(AXOLOTY_RUNS_DIR)/$(RUN_ID)/wire
# This is deliberately container-visible. The path is relative to the
# mounted worktree, while .swiftpm-cache is the shared cache mount.
AXOLOTY_RESOURCE_LEASE_ROOT ?= .swiftpm-cache/.axoloty-resource-leases
AXOLOTY_RUN_CONTAINER_ENV_VARS := AXOLOTY_RUN_ID AXOLOTY_RUNS_DIR WIRE_OUTPUT_DIR AXOLOTY_RESOURCE_LEASE_ROOT
export AXOLOTY_RUN_ID AXOLOTY_RUNS_DIR WIRE_OUTPUT_DIR AXOLOTY_RESOURCE_LEASE_ROOT
BUILD_LOCK ?= 1
export BUILD_LOCK
ifeq ($(AXOLOTY_DEVCONTAINER),1)
BUILD_DIR ?= /workspace/.build
SPM_CACHE_DIR ?= /workspace/.swiftpm-cache
else
BUILD_DIR ?= $(BUILD_CACHE_ROOT)/worktrees/$(WORKTREE_NAME)/debug
SPM_CACHE_DIR ?= $(HOME)/.cache/coaty-swift/swiftpm/$(CACHE_NAMESPACE)
endif
PACKAGE_PATH ?= .
CONTAINER_MOUNTS := -v "$(CURDIR):$(WORKDIR)$(CONTAINER_MOUNT_SUFFIX)" -v "$(BUILD_DIR):$(WORKDIR)/.build$(CONTAINER_MOUNT_SUFFIX)" -v "$(SPM_CACHE_DIR):$(WORKDIR)/.swiftpm-cache$(CONTAINER_MOUNT_SUFFIX)"
SWIFT_CACHE_ARGS := --cache-path /workspace/.swiftpm-cache
SWIFT_LOCKED_ARGS := $(SWIFT_CACHE_ARGS) --disable-automatic-resolution
COMMA := ,
AXOLOTY_TOOL_ARGS ?= --help
# The CLI enforces node and plan deadlines. This is the outer safety budget
# for a container command that stops producing progress before the CLI exits.
AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS ?= 4800
AXOLOTY_TEST_ONE_TIMEOUT_SECONDS ?= 1800
AXOLOTY_TIER_TIMEOUT_SECONDS ?= 18000
AXOLOTY_EXPLAIN_TIMEOUT_SECONDS ?= 60
AXOLOTY_RESOLVE_TIMEOUT_SECONDS ?= 1800
AXOLOTY_EMBEDDED_TIMEOUT_SECONDS ?= 7200
AXOLOTY_RELEASE_TIMEOUT_SECONDS ?= 18000
AXOLOTY_CONSUMER_REPOSITORY_URL ?= https://github.com/phynics/axoloty.git
AXOLOTY_CONSUMER_VERSION ?= $(shell tr -d '[:space:]' < VERSION)
AXOLOTY_CONSUMER_LOCAL ?= 1
AXOLOTY_CONSUMER_LOCAL_VERSION ?= 9.9.9
# Embedded Swift receives the Core checkout explicitly instead of deriving it
# from the firmware component's parent directories. run.sh translates this
# host path to the mounted container path, including external checkouts.
AXOLOTY_SOURCE_DIR ?= $(CURDIR)
export AXOLOTY_SOURCE_DIR
SERVE_MQTT_ARGS ?=
SERVE_MCP_ARGS ?= --transport stdio
SERVE_DEV_ARGS ?=
export SERVE_MQTT_ARGS SERVE_MCP_ARGS SERVE_DEV_ARGS
export AXOLOTY_CONSUMER_REPOSITORY_URL AXOLOTY_CONSUMER_VERSION AXOLOTY_CONSUMER_LOCAL AXOLOTY_CONSUMER_LOCAL_VERSION

.PHONY: serve-mqtt serve-mcp serve-dev

# Hosting base path for static DocC output. Set this to the repository name
# when publishing to a GitHub Pages project site (e.g. "axoloty" for
# https://<user>.github.io/axoloty/). Leave empty for root-hosted output.
DOC_HOSTING_BASE_PATH ?=

.PHONY: \
	help image resolve worktree-bootstrap worktree-warm \
	axoloty-tool verify verify-ci test-one test-tier explain \
	checkpoint \
	test-decoder-context-sendable \
	test-no-anycodable test-no-foundation-types test-axoloty-wire-dependencies \
	test-axoloty-wire-independent-resolution test-axoloty-wire-distribution \
	test-axoloty-semver-consumer \
	ci-preflight ci shell docs lint \
	wire-tool clean serve-mqtt serve-mcp serve-dev \
	benchmark-wire benchmark-wire-allocation benchmark-static-io-ownership-allocation benchmark-wire-bounds \
	check-embedded-core-consumer check-embedded-cutover \
	check-budget-manifest

# Quote user-provided values before placing them in a shell assignment. The
# resulting value is still passed to run.sh as one argv element.
SINGLE_QUOTE := '
DOUBLE_QUOTE := "
shell_quote = $(SINGLE_QUOTE)$(subst $(SINGLE_QUOTE),$(SINGLE_QUOTE)$(DOUBLE_QUOTE)$(SINGLE_QUOTE)$(DOUBLE_QUOTE)$(SINGLE_QUOTE),$(1))$(SINGLE_QUOTE)

help:
	@printf '%s\n' \
		'make image         Build the dev container image' \
		'make resolve PACKAGE_PATH=.  Resolve one package lockfile using the shared SwiftPM cache' \
		'make worktree-bootstrap  Prepare dependency cache and validate Package.resolved' \
		'make worktree-warm  Bootstrap and compile the current worktree' \
		'make axoloty-tool AXOLOTY_TOOL_ARGS="--help"  Run the Swift tooling CLI in-container' \
		'make verify        Run the canonical ordinary pre-PR verification plan' \
		'make test-one FILTER=...  Run one bounded suite or test filter' \
		'make test-tier TIER=ci|wire|embedded|release  Run one canonical test category' \
		'make explain TIER=...  Explain commands, policies, locks, and artifacts' \
		'make checkpoint     Run the release checkpoint validation' \
		'make serve-mqtt    Run the local MQTT broker in the container' \
		'make serve-mcp     Run the MCP service in the container' \
		'make serve-dev     Run the MQTT + MCP development stack' \
		'make test-decoder-context-sendable  Fail if the former decoder-context Sendable diagnostic returns' \
		'make test-no-anycodable  Fail if AnyCodable is used in production source' \
		'make test-no-foundation-types  Fail if forbidden Foundation types are used in production source' \
		'make test-axoloty-wire-distribution  Validate root and standalone AxolotyWire consumers' \
		'make test-axoloty-semver-consumer  Build clean semver consumers for both products' \
		'make wire-tool   Build the npx-runnable wire-compatibility CLI' \
		'make benchmark-wire  Run release wire benchmarks (p50/p95 latency + allocations)' \
		'make benchmark-wire-allocation  Host zero-per-iteration allocation gate for wire decode/route' \
		'make benchmark-static-io-ownership-allocation  Host zero-growth allocation gate for static IO ownership primitives' \
		'make check-embedded-core-consumer  Compile every portable module and a real macro consumer for Embedded Swift' \
		'make check-embedded-cutover  Validate the Core/firmware repository boundary' \
		'make benchmark-wire-bounds  Run malformed-input and capacity bounds tests' \
		'make check-budget-manifest  Validate the performance budget manifest' \
		'make ci            Run the consolidated pull-request checks' \
		'make shell         Open a shell in the Linux container' \
		'make docs          Generate DocC API documentation into the active build cache' \
		'make clean         Remove build artifacts' \
		'' \
		'BUILD_DIR and SPM_CACHE_DIR can point at different local cache directories' \
		'BUILD_DIR defaults to a shared cache under /tmp; BUILD_LOCK=0 disables waiting for isolated CI runs'

image:
	@if [ "$(AXOLOTY_DEVCONTAINER)" = "1" ]; then \
		exit 0; \
	fi; \
	test -n "$(CONTAINER_RUNTIME)" || { echo 'No podman or docker runtime found' >&2; exit 1; }; \
	mkdir -p "$(BUILD_DIR)" "$(SPM_CACHE_DIR)"; \
	inputs_sha256=$$(.devcontainer/image-inputs.sh | sha256sum | awk '{print $$1}'); \
		image_sha256=$$($(CONTAINER_RUNTIME) image inspect --format '{{ index .Config.Labels "io.axoloty.image-inputs-sha256" }}' "$(IMAGE)" 2>/dev/null || true); \
		if [ "$$inputs_sha256" = "$$image_sha256" ]; then \
			echo "Using current development image $(IMAGE) ($$inputs_sha256)"; \
		else \
			echo "Building development image $(IMAGE) ($$inputs_sha256)"; \
			$(CONTAINER_RUNTIME) build -t $(IMAGE) \
				--build-arg AXOLOTY_IMAGE_INPUTS_SHA256="$$inputs_sha256" \
				-f .devcontainer/Dockerfile .; \
		fi

resolve: image
	@mkdir -p "$(SPM_CACHE_DIR)"
	CONTAINER_COMMAND_TIMEOUT_SECONDS="$(AXOLOTY_RESOLVE_TIMEOUT_SECONDS)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" CONTAINER_ENV_VARS=AXOLOTY_RESOLVE_PACKAGE_PATH AXOLOTY_RESOLVE_PACKAGE_PATH=$(call shell_quote,$(PACKAGE_PATH)) .devcontainer/run.sh .devcontainer/resolve.sh
	@git diff --exit-code -- "$(PACKAGE_PATH)/Package.resolved"

worktree-bootstrap: resolve
	@mkdir -p "$(BUILD_DIR)"

worktree-warm: worktree-bootstrap build

# Run axoloty-tool inside the container. The stable image path is a launcher
# for the mounted worktree product, built in BUILD_DIR with the mounted SwiftPM
# cache; no project binary is extracted or baked into the image.
axoloty-tool: image
	@CONTAINER_COMMAND_TIMEOUT_SECONDS="$(AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS)" \
	AXOLOTY_HOST_RUNTIME_BRIDGE="$(AXOLOTY_HOST_RUNTIME_BRIDGE)" \
	CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" \
	BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
	CONTAINER_ENV_VARS="$(AXOLOTY_TOOL_CONTAINER_ENV_VARS) AXOLOTY_SOURCE_DIR $(AXOLOTY_RUN_CONTAINER_ENV_VARS)" \
	.devcontainer/run.sh /opt/axoloty/bin/axoloty-tool $(AXOLOTY_TOOL_ARGS)

serve-mqtt: image
	@args="$$SERVE_MQTT_ARGS"; \
	case "$$args" in *[!-[:space:]0-9A-Za-z._/:=+,]*) echo "Invalid SERVE_MQTT_ARGS" >&2; exit 2;; esac; \
	set -f; set -- $$args; \
	CONTAINER_COMMAND_TIMEOUT_SECONDS=0 CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" CONTAINER_NETWORK=host .devcontainer/run.sh /opt/axoloty/bin/ax serve mqtt "$$@"

serve-mcp: image
	@args="$$SERVE_MCP_ARGS"; \
	case "$$args" in *[!-[:space:]0-9A-Za-z._/:=+,]*) echo "Invalid SERVE_MCP_ARGS" >&2; exit 2;; esac; \
	set -f; set -- $$args; \
	CONTAINER_COMMAND_TIMEOUT_SECONDS=0 CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" CONTAINER_NETWORK=host CONTAINER_STDIN=1 CONTAINER_ENV_VARS=AXOLOTY_MCP_EXECUTABLE .devcontainer/run.sh /opt/axoloty/bin/ax serve mcp "$$@"

serve-dev: image
	@args="$$SERVE_DEV_ARGS"; \
	case "$$args" in *[!-[:space:]0-9A-Za-z._/:=+,]*) echo "Invalid SERVE_DEV_ARGS" >&2; exit 2;; esac; \
	set -f; set -- $$args; \
	CONTAINER_COMMAND_TIMEOUT_SECONDS=0 CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" CONTAINER_NETWORK=host CONTAINER_ENV_VARS=AXOLOTY_MCP_EXECUTABLE .devcontainer/run.sh /opt/axoloty/bin/ax serve dev "$$@"

verify:
	@$(MAKE) --no-print-directory axoloty-tool AXOLOTY_TOOL_ARGS=verify AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS=$(AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS)

verify-ci:
	@$(MAKE) --no-print-directory axoloty-tool AXOLOTY_TOOL_ARGS='verify --ci' AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS=$(AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS)

test-one: image
	@filter=$(call shell_quote,$(FILTER)); \
		test -n "$$filter" || { echo 'FILTER is required' >&2; exit 2; }; \
		CONTAINER_COMMAND_TIMEOUT_SECONDS="$(AXOLOTY_TEST_ONE_TIMEOUT_SECONDS)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
		CONTAINER_ENV_VARS="$(AXOLOTY_RUN_CONTAINER_ENV_VARS)" \
		.devcontainer/run.sh /opt/axoloty/bin/axoloty-tool test-one --filter "$$filter"

# The four categories are the only test entry points. The wire category needs
# the host runtime bridge, and records the G6 wire matrix when a run asks for
# that evidence; both used to live in the retired test-wire-live wrapper.
test-tier:
	@tier=$(call shell_quote,$(TIER)); \
		test -n "$$tier" || { echo 'TIER is required' >&2; exit 2; }; \
		case "$(TIER)" in wire) bridge=1;; *) bridge="$(AXOLOTY_HOST_RUNTIME_BRIDGE)";; esac; \
		$(MAKE) --no-print-directory axoloty-tool \
			AXOLOTY_TOOL_ARGS="test-tier $$tier" \
			AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS=$(AXOLOTY_TIER_TIMEOUT_SECONDS) \
			AXOLOTY_HOST_RUNTIME_BRIDGE="$$bridge"
	@if [ "$(TIER)" = "wire" ] && test -n "$${AXOLOTY_G6_WIRE_EVIDENCE:-}"; then \
		Tests/Support/checks/check-g6-wire-matrix.sh; \
	fi

explain: image
	@tier=$(call shell_quote,$(TIER)); \
		test -n "$$tier" || { echo 'TIER is required' >&2; exit 2; }; \
		CONTAINER_COMMAND_TIMEOUT_SECONDS="$(AXOLOTY_EXPLAIN_TIMEOUT_SECONDS)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
		CONTAINER_ENV_VARS=AXOLOTY_OUTPUT AXOLOTY_OUTPUT=human \
		.devcontainer/run.sh /opt/axoloty/bin/axoloty-tool explain "$$tier"

checkpoint:
	@AXOLOTY_GIT_COMMIT="$$(git rev-parse HEAD)"; \
		AXOLOTY_GIT_TREE="$$(git rev-parse HEAD^{tree})"; \
		if test -z "$$(git status --porcelain)"; then AXOLOTY_GIT_CLEAN=true; else AXOLOTY_GIT_CLEAN=false; fi; \
		export AXOLOTY_GIT_COMMIT AXOLOTY_GIT_TREE AXOLOTY_GIT_CLEAN; \
		container_env="$$(sh Tests/Support/lib/tool-container-env.sh release-checkpoint)" || exit 1; \
		test -n "$$container_env" || { echo 'release-checkpoint: empty container env allowlist' >&2; exit 1; }; \
		$(MAKE) --no-print-directory axoloty-tool AXOLOTY_TOOL_ARGS='release checkpoint' AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS=$(AXOLOTY_RELEASE_TIMEOUT_SECONDS) \
			AXOLOTY_TOOL_CONTAINER_ENV_VARS="$$container_env" \
			AXOLOTY_GIT_COMMIT="$$AXOLOTY_GIT_COMMIT" AXOLOTY_GIT_TREE="$$AXOLOTY_GIT_TREE" AXOLOTY_GIT_CLEAN="$$AXOLOTY_GIT_CLEAN" \
			AXOLOTY_EVIDENCE_DIR="$(AXOLOTY_EVIDENCE_DIR)" AXOLOTY_REPOSITORY="$(AXOLOTY_REPOSITORY)" AXOLOTY_G6_REQUIRE_SOURCE_RECEIPTS="$(AXOLOTY_G6_REQUIRE_SOURCE_RECEIPTS)" AXOLOTY_G6_HOST_RECEIPT="$(AXOLOTY_G6_HOST_RECEIPT)" AXOLOTY_G6_EMBEDDED_RECEIPT="$(AXOLOTY_G6_EMBEDDED_RECEIPT)" AXOLOTY_G6_WIRE_EVIDENCE="$(AXOLOTY_G6_WIRE_EVIDENCE)" \
			AXOLOTY_CONSUMER_REPOSITORY_URL="$(AXOLOTY_CONSUMER_REPOSITORY_URL)" AXOLOTY_CONSUMER_VERSION="$(AXOLOTY_CONSUMER_VERSION)" \
			AXOLOTY_CONSUMER_LOCAL="$(AXOLOTY_CONSUMER_LOCAL)" AXOLOTY_CONSUMER_LOCAL_VERSION="$(AXOLOTY_CONSUMER_LOCAL_VERSION)"

# The check needs build diagnostics, so it runs the build itself rather than a
# test filter. run.sh executes directly when already inside the container.
test-decoder-context-sendable: image
	@build_log=$$(mktemp); \
	trap 'rm -f "$$build_log"' EXIT; \
	if ! $(call run_container,$(AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS)) \
		swift build -Xswiftc -warnings-as-errors $(SWIFT_LOCKED_ARGS) >"$$build_log" 2>&1; \
	then cat "$$build_log"; exit 1; fi; \
	cat "$$build_log"; \
	sh Tests/Support/checks/check-decoder-context-diagnostic.sh "$$build_log"

test-no-anycodable:
	@sh Tests/Support/checks/check-no-anycodable.sh

test-no-foundation-types:
	@sh Tests/Support/checks/check-no-foundation-types.sh

test-axoloty-wire-dependencies:
	@sh Tests/Support/checks/check-axoloty-wire-dependencies.sh Packages/AxolotyWire

test-axoloty-wire-independent-resolution: image
	CONTAINER_COMMAND_TIMEOUT_SECONDS="$(AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh sh Tests/Support/checks/check-axoloty-wire-independent-resolution.sh

test-axoloty-wire-distribution: image
	CONTAINER_COMMAND_TIMEOUT_SECONDS="$(AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh sh Tests/Support/checks/check-axoloty-wire-distribution.sh

test-axoloty-semver-consumer: image
	CONTAINER_COMMAND_TIMEOUT_SECONDS="$(AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
		CONTAINER_ENV_VARS='AXOLOTY_CONSUMER_REPOSITORY_URL AXOLOTY_CONSUMER_VERSION AXOLOTY_CONSUMER_LOCAL AXOLOTY_CONSUMER_LOCAL_VERSION' \
		.devcontainer/run.sh sh Tests/Support/checks/check-axoloty-semver-consumer.sh

# Harness self-tests run as the canonical support tier in the pinned
# container. The literal test-tier call stays visible for the tier
# validator's static scan. The wire-tool npm suite stays host-side: it
# needs registry access and owns its own workflow contract.

wire-tool:
	cd Tests/Support/WireCompatibility/tool && npm ci && npm test

# environment stay on the recipe line, so `make -n`, the tier validator,
# and the wrapper tests keep scanning the real invocations.
define run_container
CONTAINER_COMMAND_TIMEOUT_SECONDS="$(1)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh
endef

ci-preflight:
	@if [ "$${CI:-}" = "true" ] && [ "$(BUILD_LOCK)" != "0" ]; then echo 'CI must set BUILD_LOCK=0 because its workspace-local build directory is not shared' >&2; exit 2; fi

ci: ci-preflight
	$(MAKE) verify-ci

shell: image
	CONTAINER_COMMAND_TIMEOUT_SECONDS=0 CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" BUILD_DIR="$(BUILD_DIR)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" .devcontainer/run.sh bash

# run.sh forwards only the names listed in CONTAINER_ENV_VARS, so the
# hosting base path must be allowlisted, not merely exported.
docs: resolve
	DOC_HOSTING_BASE_PATH="$(DOC_HOSTING_BASE_PATH)" CONTAINER_ENV_VARS=DOC_HOSTING_BASE_PATH \
		$(call run_container,$(AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS)) sh .github/scripts/build-docs.sh
	@echo "docs: mirrored .build/docc -> .build-output/docc (repo-local, survives reboot)"

lint: image
	CONTAINER_COMMAND_TIMEOUT_SECONDS="$(AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" .devcontainer/run.sh swiftlint lint --no-cache --config .swiftlint.yml

benchmark-wire: resolve
	$(call run_container,$(AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS)) /workspace/Tests/Support/checks/check-benchmark-wire.sh

# Host allocation-regression gate for the borrowed decode + static routing hot
# path (issue #490): asserts zero per-iteration heap allocation under heaptrack.
benchmark-wire-allocation: resolve
	$(call run_container,$(AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS)) /workspace/Tests/Support/checks/check-benchmark-wire-allocation.sh

# Host allocation-regression gate for the macro-generated static handler and
# fixed owning action-buffer operations introduced by G5.
benchmark-static-io-ownership-allocation: resolve
	$(call run_container,$(AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS)) /workspace/Tests/Support/checks/check-static-io-ownership-allocation.sh

check-embedded-core-consumer: image
	CONTAINER_ENV_VARS="$(AXOLOTY_RUN_CONTAINER_ENV_VARS)" \
	$(call run_container,$(AXOLOTY_EMBEDDED_TIMEOUT_SECONDS)) /workspace/Tests/Support/checks/check-embedded-swift-core.sh

check-embedded-cutover:
	Tests/Support/checks/check-embedded-cutover.sh

benchmark-wire-bounds: resolve
	$(call run_container,$(AXOLOTY_CONTAINER_COMMAND_TIMEOUT_SECONDS)) /workspace/Tests/Support/checks/check-benchmark-wire-bounds.sh

check-budget-manifest:
	Tests/Support/checks/check-budget-manifest.sh

clean:
	rm -rf "$(BUILD_DIR)"
