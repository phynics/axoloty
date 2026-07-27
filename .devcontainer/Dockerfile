# Dev/CI container for Axoloty.
#
# Based on the official Swift Docker image (Ubuntu Jammy variant). As of writing
# (2026-07-12) the latest released Swift toolchain is 6.3 (confirmed on Docker
# Hub - 6.4 has not been released yet). Verified: `podman pull swift:6.3-jammy`
# and `podman build` with this file succeed against docker.io/library/swift.
#
# This image intentionally does NOT COPY any source code in - the Axoloty
# repository is bind-mounted at runtime (see the root Makefile and
# .devcontainer/devcontainer.json), so editing source does not require
# rebuilding the image.
ARG SWIFT_VERSION=6.3
FROM swift:${SWIFT_VERSION}-jammy

# Build essentials commonly required by Swift Package Manager on Linux,
# in particular for Foundation's networking stack (URLSession/curl backend)
# and for packages that build/link against system libraries via pkg-config.
# Some rootless Podman storage backends preserve a non-writable /tmp mode from
# the base image. apt needs it for its signed-repository configuration files.
RUN chmod 1777 /tmp \
    && apt-get update && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev \
    libssl-dev \
    git \
    pkg-config \
    mosquitto \
    curl \
    unzip \
    heaptrack \
    && rm -rf /var/lib/apt/lists/*

# SwiftLint for the `make lint` target (also run in CI). Uses the static
# Linux binary so the image needs no extra runtime libs. Pinned to a
# released tag; bumped deliberately.
ARG SWIFTLINT_VERSION=0.65.0
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

WORKDIR /workspace
