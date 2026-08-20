// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// The bounded-runtime source is pure Swift. ESP-IDF still requires a bridge
// header for an Embedded Swift component; it also exposes the compile-only
// entry point so the linker retains the specialization probe.
void bounded_portable_runtime_probe(void);
