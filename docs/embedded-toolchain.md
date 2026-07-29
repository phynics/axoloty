# ESP32-C6 toolchain pinning and workflow

Status: implements issue #297, updated by #320 and #321. The ESP32-C6
toolchain is included in the single dev image (`axoloty-dev`). Embedded
Swift cross-compilation is working — AxolotyWire compiles and runs
on-device via the `espressif/idf_swift` component.

## NixOS host prerequisites

Everything below runs on the NixOS host. Product and Embedded Swift work goes
through the Makefile into the pinned container. Native Swift is supported only
for the macOS offline workflow.

- **dialout group.** The user that runs rootless Podman must be able to open
  the serial device:
  ```sh
  sudo usermod -aG dialout "$USER"
  ```
  Log out and back in (or `newgrp dialout`) for the change to take effect.

- **udev rules.** The Espressif USB JTAG/serial debug unit presents as
  `303a:1001`. A stable udev rule avoids the device snapping to root-only on
  replug. On NixOS add to `configuration.nix`:
  ```nix
  services.udev.extraRules = ''
    SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", ATTRS{idProduct}=="1001", GROUP="dialout", MODE="0660"
  '';
  ```
  then `sudo nixos-rebuild switch` and replug the board.

- **Rootless Podman device access.** Device targets forward `/dev/ttyACM0`
  into the container via `CONTAINER_DEVICES` (see `.devcontainer/run.sh`). For
  rootless Podman to open the device, the host user must own or be in the
  group that owns it (the udev rule above arranges this). If rootless Podman
  still cannot open the device (some userns configurations block device
  nodes), the runner automatically selects a working non-interactive sudo
  wrapper. It can also be selected explicitly:
  ```sh
  SUDO=/run/wrappers/bin/sudo make embedded-swift-flash
  ```

- **Do not run native Swift on Linux.** The Linux host has no supported Swift
  product toolchain; use `make check` or a focused Make wrapper. See `AGENTS.md`.

## Toolchain pinning

All toolchain components are in the single `Dockerfile`:

| Component | Version | Source |
|---|---|---|
| Swift | `6.3` | `swift:6.3-jammy` base image |
| ESP-IDF | `v5.4` (pinned tag) | `git clone --depth 1 --branch v5.4` |
| RISC-V GCC | ESP-IDF v5.4 bundled | installed by `./install.sh esp32c6` |
| OpenOCD | Espressif build, bundled with ESP-IDF | installed by `./install.sh esp32c6` |
| espflash | `3.3.0` | prebuilt binary from `esp-rs/espflash` releases |
| CMake | `>= 3.29` (via pip) | required by `espressif/idf_swift` component |
| SwiftLint | `0.65.0` | prebuilt static binary |

All versions are declared as `ARG`s at the top of `.devcontainer/Dockerfile`
and bumped deliberately. Rebuilding the image is required to change any of
them: `make image`.

## Build / flash / monitor workflow

```sh
make image                        # build the dev image (includes ESP32-C6 toolchain)
make embedded-toolchain-doctor    # verify tool versions + /dev/ttyACM0 access
make embedded-device-info          # query the board, write .testing/embedded/device-manifest.json
make embedded-device-smoke         # build, flash, monitor C smoke image (30s deadline)
make embedded-swift-build          # build the Embedded Swift firmware
make embedded-swift-flash           # build, flash, monitor Swift smoke + AxolotyWire exercise
make embedded-reproducible-build    # build twice from clean, compare .bin SHA-256
make hardware-check                 # skip successfully when no board is attached
make hardware-require               # fail unless the selected board is attached
```

Every target runs inside the `axoloty-dev` container. The `axoloty-tool` hardware targets
forward `AXOLOTY_DEVICE` (default `/dev/ttyACM0`) only when that path exists;
ordinary checks never request device access. The incremental Swift build cache is
external, while its firmware is mirrored to
`.build-output/embedded-swift/axoloty-swift.bin`. Runtime evidence lands under
`.testing/embedded/` (outside `/tmp`, so it survives the container):

| File | Produced by |
|---|---|
| `device-manifest.json` | `embedded-device-info` |
| `device-info-raw.txt` | `embedded-device-info` |
| `smoke-log.txt` | `embedded-device-smoke` |
| `swift-smoke-log.txt` | `embedded-swift-flash` |
| `swift-smoke-result.json` | `embedded-swift-flash` |
| `reproducible-build.json` | `embedded-reproducible-build` |

## Embedded Swift status

Swift 6.3 compiles AxolotyWire for `riscv32-none-none-eabi` using
`-enable-experimental-feature Embedded`. The `espressif/idf_swift` ESP-IDF
component (v1.0.1) integrates the Swift compiler into the ESP-IDF build
system via `idf_component_register_swift()`.

The Swift firmware (`Embedded/swift/`) compiles AxolotyWire as a separate
Embedded Swift module and links it into the application. Verified on physical
ESP32-C6:
`AXOLOTY_SMOKE_OK` captured, `WireReader.readUUID` and `TopicView.eventType`
work on-device.

Known limitations:
- `print()` and `String` pull in Unicode normalization runtime symbols that
  are not linked. Use `axoloty_print` (C wrapper around `esp_rom_printf`)
  and `StaticString` instead.
- Variadic C functions (`printf`, `ESP_LOGI`) are unavailable in Embedded
  Swift. The `log_helper.c` wrapper provides a fixed-signature alternative.

## Reproducible builds

`Embedded/sdkconfig.defaults` sets `CONFIG_APP_REPRODUCIBLE_BUILD=y`, which
makes ESP-IDF omit non-deterministic inputs (build timestamps, absolute
paths) from the app binary.

To verify:

```sh
make embedded-reproducible-build
```

The script builds `Embedded/` twice from a full clean, records the SHA-256 of
`build/axoloty-smoke.bin` each time, and writes both hashes plus a boolean
`reproducible` field to `.testing/embedded/reproducible-build.json`. It exits
non-zero if the hashes differ.
