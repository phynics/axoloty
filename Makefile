SHELL := /bin/sh

IMAGE ?= coatyswift-dev
BROKER_NAME ?= coatyswift-mosquitto
CONTAINER_RUNTIME ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
WORKDIR := /workspace
COMMA := ,

.PHONY: help image build test test-unit test-module test-fuzz fuzz-long test-fast test-wire test-wire-live test-wire-all ci-fast ci broker broker-stop shell clean

help:
	@printf '%s\n' \
		'make image       Build the Linux Swift development image' \
		'make build       Build Axoloty in the Linux container' \
		'make test        Run the full test suite (starts Mosquitto)' \
		'make test-unit   Run ObjectMatcherTests' \
		'make test-module Run targeted infrastructure module tests' \
		'make test-fuzz   Run deterministic property/fuzz tests' \
		'make fuzz-long   Run an auditable multi-seed fuzz campaign' \
		'make test-fast   Run unit, module, fuzz, and offline wire tests' \
		'make test-wire   Run offline wire fixtures and capture tests' \
		'make test-wire-live Run live CoatyJS compatibility scenarios' \
		'make test-wire-all Run offline and live compatibility suites' \
		'make ci-fast     Run the build and fast test suite' \
		'make ci          Run all pull-request CI checks' \
		'make broker      Start Mosquitto on localhost:1883' \
		'make broker-stop Stop the background Mosquitto container' \
		'make shell       Open a shell in the Linux container' \
		'make clean       Remove Swift build artifacts'

image:
	@test -n "$(CONTAINER_RUNTIME)" || (echo 'No podman or docker runtime found' >&2; exit 1)
	$(CONTAINER_RUNTIME) build -t $(IMAGE) -f .devcontainer/Dockerfile .devcontainer

build: image
	$(CONTAINER_RUNTIME) run --rm -v "$(CURDIR):$(WORKDIR)" -w $(WORKDIR) $(IMAGE) swift build

test: image
	$(CONTAINER_RUNTIME) run --rm -v "$(CURDIR):$(WORKDIR)" -w $(WORKDIR) $(IMAGE) \
		sh -c 'pgrep mosquitto >/dev/null 2>&1 || mosquitto -d; swift test'

test-unit: image
	$(CONTAINER_RUNTIME) run --rm -v "$(CURDIR):$(WORKDIR)" -w $(WORKDIR) $(IMAGE) \
		swift test --filter ObjectMatcherTests

test-module: image
	$(CONTAINER_RUNTIME) run --rm -v "$(CURDIR):$(WORKDIR)" -w $(WORKDIR) $(IMAGE) swift test --filter CommunicationTopicTests
	$(CONTAINER_RUNTIME) run --rm -v "$(CURDIR):$(WORKDIR)" -w $(WORKDIR) $(IMAGE) swift test --filter PayloadCoderTests
	$(CONTAINER_RUNTIME) run --rm -v "$(CURDIR):$(WORKDIR)" -w $(WORKDIR) $(IMAGE) swift test --filter ObjectTypeRegistryTests

test-fuzz: image
	$(CONTAINER_RUNTIME) run --rm -v "$(CURDIR):$(WORKDIR)" -w $(WORKDIR) \
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
	$(CONTAINER_RUNTIME) run --rm -v "$(CURDIR):$(WORKDIR)" -w $(WORKDIR) $(IMAGE) \
		swift test --filter WireFixtureTests
	$(CONTAINER_RUNTIME) run --rm -v "$(CURDIR):$(WORKDIR)" -w $(WORKDIR) $(IMAGE) \
		swift test --filter LifecycleCompatibilityScenarioTests
	$(CONTAINER_RUNTIME) run --rm -v "$(CURDIR):$(WORKDIR)" -w $(WORKDIR) $(IMAGE) \
		sh -c "PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/WireCompatibility/Capture -p 'test_*.py' -v"
	$(CONTAINER_RUNTIME) run --rm -v "$(CURDIR):$(WORKDIR)" -w $(WORKDIR) $(IMAGE) \
		sh -c "PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/WireCompatibility/Legacy -p 'test_*.py' -v"
	$(CONTAINER_RUNTIME) run --rm -v "$(CURDIR):$(WORKDIR)" -w $(WORKDIR) $(IMAGE) \
		sh -c "PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/WireCompatibility/Live -p 'test_*.py' -v"
	$(CONTAINER_RUNTIME) run --rm -v "$(CURDIR):$(WORKDIR)" -w $(WORKDIR) $(IMAGE) \
		python3 Tests/Support/validate_test_tiers.py Tests/Support/test-tiers.json

test-wire-live:
	CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) Tests/WireCompatibility/Live/run-coatyjs-advertise.sh
	CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) Tests/WireCompatibility/Live/run-coatyjs-core.sh
	CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) Tests/WireCompatibility/Lifecycle/Live/run-coatyjs-last-will.sh
	CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) Tests/WireCompatibility/Reverse/run-axoloty-advertise.sh

test-wire-all: test-wire test-wire-live

test-fast: test-unit test-module test-fuzz test-wire

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
	$(CONTAINER_RUNTIME) run --rm -it -v "$(CURDIR):$(WORKDIR)" -w $(WORKDIR) $(IMAGE) bash

clean:
	rm -rf .build
