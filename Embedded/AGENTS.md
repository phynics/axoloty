# Embedded instructions

Embedded firmware is a deployment of the static runtime profile, not a separate protocol implementation. Firmware may own platform and transport integration, identity persistence, clocks, Wi-Fi, sensors/actuators, storage, and the main loop; protocol rules belong in portable packages.

Use root Make targets for Embedded Swift and ESP-IDF work. `make embedded-toolchain-doctor` is the device-independent setup diagnostic. Ordinary verification must not probe, reserve, flash, or request device privileges. Hardware targets are explicitly opt-in.

Never commit Wi-Fi or broker credentials. Device-specific paths, credentials, broker reachability, and live timing belong in operator configuration rather than repository-wide policy.
