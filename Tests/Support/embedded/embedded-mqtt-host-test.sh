#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu

# Compile the firmware-local Swift overlay with a host-only C HAL. This does
# not compile or link ESP-IDF and cannot be used by the production image.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
compiler=${CC:-clang}
command -v "$compiler" >/dev/null
command -v swiftc >/dev/null

"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -I Embedded/swift/main \
  -c Tests/Support/embedded/embedded-mqtt-host-hal.c -o "$tmp/hal.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -I Embedded/swift/main \
  -c Embedded/swift/main/mqtt_event_validation.c -o "$tmp/validation.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -I Embedded/swift/main \
  -c Embedded/swift/main/runtime_identity.c -o "$tmp/identity.o"
swiftc -D EMBEDDED_MQTT_HOST_TEST \
  Embedded/swift/main/EmbeddedMQTTClient.swift \
  Tests/Support/embedded/embedded-mqtt-host-test.swift \
  "$tmp/hal.o" "$tmp/validation.o" "$tmp/identity.o" -o "$tmp/embedded-mqtt-host-test"

# Nix's standalone Swift compiler does not always add the dispatch library to
# the executable search path. Native CI images already provide it.
swift_runtime=$(swiftc -print-target-info | awk -F'"' '/runtimeLibraryPaths/{getline; print $2; exit}')
dispatch_dir=$(dirname "$(find /nix/store -name libdispatch.so 2>/dev/null | head -1)")
LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:$swift_runtime:$dispatch_dir" \
  "$tmp/embedded-mqtt-host-test"
echo "embedded MQTT host seam tests passed"
