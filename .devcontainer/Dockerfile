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
#
# The image includes both the host development tools (Swift, SwiftLint,
# mosquitto, heaptrack) and the ESP32-C6 embedded toolchain (ESP-IDF,
# RISC-V GCC, espflash). There is one image for all targets.
ARG SWIFT_VERSION=6.3
ARG ESP_IDF_VERSION=v5.4
ARG ESPFLASH_VERSION=3.3.0
ARG SWIFTLINT_VERSION=0.65.0

FROM swift:${SWIFT_VERSION}-jammy

ARG ESP_IDF_VERSION
ARG ESPFLASH_VERSION
ARG SWIFTLINT_VERSION

# Build essentials commonly required by Swift Package Manager on Linux,
# in particular for Foundation's networking stack (URLSession/curl backend)
# and for packages that build/link against system libraries via pkg-config.
# Also includes ESP-IDF build prerequisites (ninja-build, python3, libusb).
# CMake is installed via pip (not apt) because the espressif/idf_swift
# component requires CMake >= 3.29, and the apt version on Ubuntu 22.04
# is 3.22.
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
        ninja-build \
        nodejs \
        npm \
        python3 \
        python3-pip \
        python3-venv \
        libusb-1.0-0-dev \
        libudev-dev \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir "cmake>=3.29"

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

# Clone ESP-IDF at the pinned tag and materialize every submodule in the image.
# This keeps offline embedded checks from mutating the toolchain or downloading
# dependencies at first use. `install.sh esp32c6` downloads only the RISC-V
# GCC toolchain, OpenOCD, and Python deps needed for that target.
RUN git clone --depth 1 --branch ${ESP_IDF_VERSION} \
        https://github.com/espressif/esp-idf.git /opt/esp/idf \
    && cd /opt/esp/idf \
    && git submodule update --init --recursive \
    && ./install.sh esp32c6

# espflash (Rust) for board-info / flashing without the full IDF monitor.
# Downloaded as a prebuilt static binary from GitHub releases so the image
# needs no Rust toolchain. The asset is a zip containing the `espflash`
# binary at the archive root.
RUN curl -fsSL -o /tmp/espflash.zip \
        https://github.com/esp-rs/espflash/releases/download/v${ESPFLASH_VERSION}/espflash-x86_64-unknown-linux-gnu.zip \
    && unzip -q -o /tmp/espflash.zip -d /tmp/espflash-extract \
    && install -m 0755 /tmp/espflash-extract/espflash /usr/local/bin/espflash \
    && rm -rf /tmp/espflash.zip /tmp/espflash-extract \
    && espflash --version

# Non-root user for direct device access when the container is run as a
# regular user. The dialout group owns /dev/ttyACM* on most Linux distros.
RUN useradd --no-create-home --shell /usr/sbin/nologin esp \
    && usermod -a -G dialout esp

ENV IDF_PATH=/opt/esp/idf
ENV PATH="${IDF_PATH}/tools:${PATH}"

WORKDIR /workspace
