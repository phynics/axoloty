# Dev/CI container for Axoloty.
#
# Based on the official Swift Docker image (Ubuntu Jammy variant). As of writing
# (2026-07-12) the latest released Swift toolchain is 6.3 (confirmed on Docker
# Hub - 6.4 has not been released yet). Verified: `podman pull swift:6.3-jammy`
# and `podman build` with this file succeed against docker.io/library/swift.
#
# This image intentionally does NOT COPY any project source in - the Axoloty
# repository is bind-mounted at runtime (see the root Makefile and
# .devcontainer/devcontainer.json), so editing source does not require
# rebuilding the image. Mounted-worktree launchers build products into the
# mounted SwiftPM and worktree-specific build caches.
#
# The image carries the host development tools (Swift, SwiftLint, mosquitto,
# heaptrack). Firmware and the ESP32-C6 toolchain live in the dedicated
# `axoloty-embedded` repository.
ARG SWIFT_VERSION=6.3
ARG SWIFTLINT_VERSION=0.65.0
ARG NODE_VERSION=22.17.1
ARG CMAKE_VERSION=3.29.6

FROM swift:${SWIFT_VERSION}-jammy

ARG SWIFTLINT_VERSION
ARG NODE_VERSION
ARG CMAKE_VERSION

# Build essentials commonly required by Swift Package Manager on Linux,
# in particular for Foundation's networking stack (URLSession/curl backend)
# and for packages that build/link against system libraries via pkg-config.
# CMake is installed via pip because the Ubuntu 22.04 apt version is 3.22.
# Some rootless Podman storage backends preserve a non-writable /tmp mode from
# the base image. apt needs it for its signed-repository configuration files.
RUN chmod 1777 /tmp \
    && apt-get update && apt-get install -y --no-install-recommends \
        libcurl4-openssl-dev \
        libssl-dev \
        git \
        make \
        pkg-config \
        ripgrep \
        mosquitto \
        curl \
        unzip \
        heaptrack \
        ninja-build \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/* \
     && pip3 install --no-cache-dir "cmake==${CMAKE_VERSION}"

# Node drives repository-owned JavaScript validation and capture tools. Ubuntu
# Jammy's Node 12 package cannot parse the modern syntax used by those tools,
# so install a pinned LTS distribution instead of relying on apt.
RUN curl -fsSL -o /tmp/node.tar.xz \
        https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && node --version \
    && npm --version

# SwiftLint for the `make lint` target (also run in CI). Uses the static
# Linux binary so the image needs no extra runtime libs. Pinned to a
# released tag; bumped deliberately.
RUN curl -fsSL -o /tmp/swiftlint.zip \
        https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/swiftlint_linux_amd64.zip \
    && unzip -q /tmp/swiftlint.zip -d /tmp/swiftlint-extract \
    && install -m 0755 /tmp/swiftlint-extract/swiftlint-static /usr/local/bin/swiftlint \
    && rm -rf /tmp/swiftlint.zip /tmp/swiftlint-extract \
    && swiftlint version

# Allow the integration tests to connect to the in-container broker without
# credentials. The Makefile starts Mosquitto for each test invocation.
RUN printf 'listener 1883\nallow_anonymous true\n' \
    > /etc/mosquitto/conf.d/coatyswift.conf

# These are mounted-worktree launchers, not compiled project products. Stable
# paths preserve the Make/control-plane contract without putting root-package
# source or binaries in the image.
COPY .devcontainer/ax /opt/axoloty/bin/ax
COPY .devcontainer/axoloty-tool /opt/axoloty/bin/axoloty-tool
COPY .devcontainer/axoloty-mcp /opt/axoloty/bin/axoloty-mcp
COPY .devcontainer/axoloty-cli /opt/axoloty/bin/axoloty-cli
RUN chmod 0755 /opt/axoloty/bin/ax /opt/axoloty/bin/axoloty-tool /opt/axoloty/bin/axoloty-mcp /opt/axoloty/bin/axoloty-cli
ARG AXOLOTY_IMAGE_INPUTS_SHA256=unknown
LABEL io.axoloty.image-inputs-sha256="${AXOLOTY_IMAGE_INPUTS_SHA256}"
ARG DOCKER_CLI_VERSION=27.5.1
RUN curl -fsSL -o /tmp/docker.tgz \
        https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz \
    && tar -xzf /tmp/docker.tgz -C /tmp \
    && install -m 0755 /tmp/docker/docker /usr/local/bin/docker \
    && rm -rf /tmp/docker /tmp/docker.tgz \
    && docker --version
WORKDIR /workspace
