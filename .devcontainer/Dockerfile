# Dev/CI container for CoatySwift.
#
# Based on the official Swift Docker image (Ubuntu Jammy variant). As of writing
# (2026-07-12) the latest released Swift toolchain is 6.3 (confirmed on Docker
# Hub - 6.4 has not been released yet). Verified: `podman pull swift:6.3-jammy`
# and `podman build` with this file succeed against docker.io/library/swift.
#
# This image intentionally does NOT COPY any source code in - the CoatySwift
# repository is bind-mounted at runtime (see the root Makefile and
# .devcontainer/devcontainer.json), so editing source does not require
# rebuilding the image.
ARG SWIFT_VERSION=6.3
FROM swift:${SWIFT_VERSION}-jammy

# Build essentials commonly required by Swift Package Manager on Linux,
# in particular for Foundation's networking stack (URLSession/curl backend)
# and for packages that build/link against system libraries via pkg-config.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev \
    libssl-dev \
    git \
    pkg-config \
    mosquitto \
    && rm -rf /var/lib/apt/lists/*

# Allow the integration tests to connect to the in-container broker without
# credentials. The Makefile starts Mosquitto for each test invocation.
RUN printf 'listener 1883\nallow_anonymous true\n' \
    > /etc/mosquitto/conf.d/coatyswift.conf

WORKDIR /workspace
