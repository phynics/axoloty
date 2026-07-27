# ESP32-C6 toolchain pinning and workflow

Status: implements issue #297. Pins the ESP32-C6 toolchain inside an
extension of the base dev image and defines Makefile targets for toolchain
verification, device discovery, the smoke run, and reproducible-build checks.
The Swift RISC-V cross-compile path is intentionally stubbed (see
[Embedded Swift status](#embedded-swift-status)); the smoke image is a C
program built with ESP-IDF's RISC-V GCC.

## NixOS host prerequisites

Everything below runs on the NixOS host. None of it invokes `swift` directly —
all Swift/container work goes through the Makefile.

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

- **Rootless Podman device access.** `make embedded-*` forwards `/dev/ttyACM0`
  into the container via `CONTAINER_DEVICES` (see `.devcontainer/run.sh`). For
  rootless Podman to open the device, the host user must own or be in the
  group that owns it (the udev rule above arranges this). If rootless Podman
  still cannot open the device (some userns configurations block device
  nodes), fall back to Docker with `sudo`:
  ```sh
  CONTAINER_RUNTIME=docker sudo -E make embedded-device-smoke
  ```

- **Never run native `swift` on the host.** The host has no Swift toolchain
  wired to this repo; every Swift invocation goes through `make` (which runs
  inside the container). See `AGENTS.md`.

## Toolchain pinning

| Component | Version | Source |
|---|---|---|
| ESP-IDF | `v5.4` (pinned tag) | `git clone --depth 1 --branch v5.4` in `Dockerfile.embedded` |
| RISC-V GCC | the build ESP-IDF v5.4 ships | installed by `./install.sh esp32c6` |
| OpenOCD | Espressif build, bundled with ESP-IDF | installed by `./install.sh esp32c6` |
| espflash | `3.3.0` | prebuilt binary from `esp-rs/espflash` releases |
| Swift | `6.3` (from base image) | `swift:6.3-jammy`; RISC-V cross-compile not yet available |

All versions are declared as `ARG`s at the top of `.devcontainer/Dockerfile.embedded`
and bumped deliberately. Rebuilding the image is required to change any of them.

## Build / flash / monitor workflow

```sh
make embedded-image                # build the ESP32-C6 toolchain image
make embedded-toolchain-doctor     # verify tool versions + /dev/ttyACM0 access
make embedded-device-info          # query the board, write .testing/embedded/device-manifest.json
make embedded-device-smoke         # build, flash, monitor for AXOLOTY_SMOKE_OK (30s deadline)
make embedded-reproducible-build   # build twice from clean, compare .bin SHA-256
```

Every target forwards `/dev/ttyACM0` via `CONTAINER_DEVICES` and runs the
script inside the `$(IMAGE)-embedded` container. Output artifacts land under
`.testing/embedded/` (outside `/tmp`, so they survive the container):

| File | Produced by |
|---|---|
| `device-manifest.json` | `embedded-device-info` |
| `device-info-raw.txt` | `embedded-device-info` |
| `smoke-log.txt` | `embedded-device-smoke` |
| `reproducible-build.json` | `embedded-reproducible-build` |

### Device manifest shape

`device-manifest.json` is generated at runtime (it is gitignored because it
contains device-specific data like the MAC address). Its shape:

```json
{
  "$comment": "Populated by make embedded-device-info. Do not edit manually.",
  "device": {
    "chipModel": "",
    "chipRevision": "",
    "macAddress": "",
    "flashId": "",
    "flashSize": "",
    "usbSerial": "",
    "boardModel": ""
  },
  "toolchain": {
    "espIdfVersion": "",
    "riscvGccVersion": "",
    "openocdVersion": "",
    "espflashVersion": "",
    "swiftRiscvCapable": false
  },
  "capturedAt": ""
}
```

`boardModel` is left empty by the script — it is the silkscreen/declared
carrier model and is filled in manually.

## Embedded Swift status

Swift 6.3 (the toolchain in the base image) recognizes the
`riscv32-unknown-none-elf` target triple but **cannot cross-compile** to it:
the standard library is unavailable for that target, `-parse-as-library` does
not bypass the stdlib requirement, and `-disable-stdlib-import` is not a
recognized flag. `check-embedded-toolchain.sh` runs this probe and reports
the result as **informational** (it does not fail the doctor — the C
toolchain is sufficient for the smoke image).

Consequences:

- The smoke image (`Embedded/main/main.c`) is a C program built with ESP-IDF's
  RISC-V GCC. It prints `AXOLOTY_SMOKE_OK` and restarts.
- `Embedded/main/smoke.swift` is the intended Embedded Swift entry point,
  kept in the tree as a placeholder. It is **not** registered in
  `Embedded/main/CMakeLists.txt`, so the ESP-IDF build ignores it.
- `Embedded/main/CMakeLists.txt` documents why the Swift file is excluded.
- Full Embedded Swift support requires a custom Swift toolchain with a
  RISC-V backend. This is tracked for Phase 4; see the v1 tracker (#272).

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
